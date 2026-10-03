module Rho
  module IngressTelegram
    # Numbers select the most recently displayed UUIDs, never a moving queue
    # position. The channel remembers no second copy of pending work or content.
    module QueueWorkflow
      def queue_list(update)
        route = room(update)
        return "No conversation is open. Send a message to start one." unless route["current"]

        id = route.fetch("current")
        rows = @bridge.inputs(id, workspace_public_id: workspace_for(route, id))
        text = if rows.empty?
          "No requests are waiting in this conversation."
        else
          lines = rows.each_with_index.map { |row, index| queue_line(row, index + 1) }
          "Waiting requests:\n#{lines.join("\n")}\nUse /queue edit NUMBER TEXT, /queue reschedule NUMBER in 20m|at TIME|now, or /queue cancel NUMBER. " \
            "Numbers refer to this chat's most recent /queue list."
        end
        # Replaying a list after its reply was queued must not publish different
        # targets beside the old text. Save both through the existing update receipt.
        @state.change do |document|
          selections = document.fetch("routes").fetch(update.route_key)["queue_selections"] ||= {}
          selections[update.user_id] = {
            "conversation_id" => id, "inputs" => rows.map { |row| row.fetch("public_id") },
          }
          document.fetch("pending_update").merge!("control_status" => "applied", "control_result" => text)
        end
        text
      end

      def queue_edit(update, number, text)
        change_queued_input(update, number, edit: true) do |id, input, workspace_id|
          @bridge.update_input(id, input.fetch("public_id"), text: text, workspace_public_id: workspace_id)
          "Waiting request #{number} updated."
        end
      end

      def queue_cancel(update, number)
        change_queued_input(update, number, edit: false) do |id, input, workspace_id|
          @bridge.delete_input(id, input.fetch("public_id"), workspace_public_id: workspace_id)
          "Waiting request #{number} canceled."
        end
      end

      def queue_reschedule(update, number, expression)
        at = saved_delivery_time(expression)
        change_queued_input(update, number, edit: true) do |id, input, workspace_id|
          row = @bridge.update_input(id, input.fetch("public_id"), schedule: { "deliver_at" => at }, workspace_public_id: workspace_id)
          "Waiting request #{number} rescheduled for #{row.fetch("deliver_at")}. It runs when this conversation can take its next request."
        end
      end

      def work_status(update)
        route = room(update)
        lines = if (id = route["current"])
          workspace_id = workspace_for(route, id)
          conversation = @bridge.conversation(id, workspace_public_id: workspace_id)
          inputs = @bridge.inputs(id, workspace_public_id: workspace_id)
          snapshot = @bridge.snapshot(id, workspace_public_id: workspace_id, inputs: inputs)
          pending = @bridge.pending(id, workspace_public_id: workspace_id)
          workspace = @bridge.workspace(workspace_id)
          title = conversation["title"].to_s.strip
          ["Conversation: #{id}#{" — #{Render.preview(title, limit: 120)}" unless title.empty?}",
            "Workspace: #{Render.preview(workspace.fetch("name"), limit: 100)} (#{workspace_id})",
            "Next request model: #{route["model"] || @default_model || "Not configured"}",
            "Status: #{snapshot.fetch("status")}", "Current action: #{snapshot.fetch("action", "Waiting for work")}",
            "Queued: #{inputs.count { |row| row["delivery_mode"] == "queue" }}",
            "Steering updates: #{inputs.count { |row| row["delivery_mode"] == "steer" }}",
            "Blocked: #{inputs.count { |row| row["state"] == "blocked" }}",
            "Pending requests: #{pending.length}",
            "Use /queue to view or change waiting requests."]
        else
          ["Status: idle", "No conversation is open."]
        end
        if id
          tasks = @state.read.fetch("requests").values.select do |row|
            row.fetch("conversation_id") == id && row["input_id"] &&
              row.fetch("room_key") == update.room_key && (owner?(update) || row.fetch("owner_id") == update.user_id)
          end.last(10)
          unless tasks.empty?
            lines << "Recent task IDs:\n#{tasks.map { |row| row.fetch("input_id") }.join("\n")}"
            lines << "Use /status TASK_ID, /stop TASK_ID or /steer TASK_ID <text>."
          end
        end
        issues = @state.read.fetch("deliveries").values.count do |entry|
          entry.fetch("chat_id") == update.chat_id && entry["topic_id"] == update.topic_id &&
            %w[uncertain refused].include?(entry.fetch("status"))
        end
        lines << "Delivery issues: #{issues}."
        lines << "Check rho telegram status locally; uncertain messages are not resent automatically." if issues.positive?
        lines.join("\n")
      end

      private

        def queue_line(row, number)
          details = [row.fetch("state")]
          details << row.fetch("blocked_reason") if row["blocked_reason"]
          if kernel_input?(row)
            details << "background result, read-only"
          elsif row["state"] == "steering"
            details << "steering, cancel only"
          end
          attachments = row.fetch("attachments", [])
          details << "#{attachments.length} attachment(s)" unless attachments.empty?
          details << "not before #{row.fetch("deliver_at")}" if row["deliver_at"]
          text = Render.preview(row["text"].to_s, limit: 220)
          text = "[No text]" if text.empty?
          "#{number}. #{text} (#{details.join("; ")})\n   Input: #{row.fetch("public_id")}"
        end

        def change_queued_input(update, number, edit:)
          if update.media || update.unsupported_media?
            return "Queue controls accept text only. Send attachments as a normal queued message."
          end
          route = room(update)
          id = route["current"]
          selected = route.fetch("queue_selections", {})[update.user_id]
          unless id && selected && selected.fetch("conversation_id") == id
            return "Use /queue to list this conversation's waiting requests first."
          end
          input_id = selected.fetch("inputs")[number - 1]
          return "That number is not in the most recent list. Use /queue to refresh it." unless input_id

          workspace_id = workspace_for(route, id)
          input = @bridge.inputs(id, workspace_public_id: workspace_id).find { |row| row.fetch("public_id") == input_id }
          unless input && %w[pending blocked steering].include?(input.fetch("state"))
            return "That request is no longer waiting. Use /queue to refresh the list."
          end
          return "Background result messages are read-only. Stop their source work if needed." if kernel_input?(input)
          document = @state.read
          request_id = document.fetch("work").dig(input_id, "request_id")
          request = document.fetch("requests")[request_id]
          unless owner?(update) || (request && request.fetch("owner_id") == update.user_id)
            return "Only this request's sender or the bot owner can edit or cancel it."
          end
          if edit && input.fetch("state") == "steering"
            return "That instruction is already waiting for the next model step. Use /queue cancel #{number} to cancel it; it cannot be edited."
          end
          if edit && !owner?(update)
            allowed = input_tool_names(user_id: update.user_id, group: update.group?, route_key: update.route_key, conversation_id: id)
            unless input["tool_names"] && (input.fetch("tool_names") - allowed).empty?
              return "This request was not admitted with read-only tools. Send a new request, or ask the bot owner to change it."
            end
          end

          control { yield(id, input, workspace_id) }
        end

        def kernel_input?(input) = %w[task_result child].include?(input["origin"])
    end
  end
end
