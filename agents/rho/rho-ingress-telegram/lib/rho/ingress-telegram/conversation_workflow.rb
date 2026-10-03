require "json"

module Rho
  module IngressTelegram
    # IM commands select existing conversation/turn/loop authorities. Only the
    # destination, frozen control target and delivery watch live in channel state.
    module ConversationWorkflow
      def conversation_command(update, action, argument)
        reference = argument if %w[archive restore].include?(action) && !argument.empty?
        id, workspace_id = selected_conversation(update, reference: reference)
        case action
        when "history" then history_command(update, id, workspace_id, argument)
        when "rename"
          return "Use /rename TITLE." if argument.strip.empty?

          control do
            @bridge.rename_conversation(id, title: argument, workspace_public_id: workspace_id)
            "Conversation renamed."
          end
        when "archive", "restore"
          control do
            @bridge.public_send("#{action}_conversation", id, workspace_public_id: workspace_id)
            action == "archive" ? "Conversation archived. Use /restore to restore it, or /new to start another." : "Conversation restored."
          end
        when "fork", "regenerate", "variants", "variant", "edit", "undo"
          history_control(update, id, workspace_id, action, argument)
        when "context"
          return "Use /context." unless argument.empty?

          ensure_memory_binding(update, room(update), id, workspace_id)
          preview = @bridge.context_preview(id, model: @state.read.fetch("pending_update")["model"],
            isolated: !owner?(update), workspace_public_id: workspace_id)
          "Context preview:\n#{Render.preview(JSON.pretty_generate(preview), limit: 12_000)}"
        when "compact"
          return "Use /compact." unless argument.empty?
          control do
            @bridge.compact(id, workspace_public_id: workspace_id)
            "Context compaction requested."
          end
        else
          raise Rho::Error, "Unknown conversation command."
        end
      end

      def execution_command(update, argument)
        action, task_id, task_key, extra = argument.split(/\s+/, 4)
        unless %w[pause resume retry abandon].include?(action) && !extra &&
            (task_key.nil? || %w[retry abandon].include?(action)) &&
            (task_id.nil? || Rho::Gateway::Commands::TASK_ID.match?(task_id))
          return "Use /task pause|resume|retry|abandon [TASK_ID]. Retry and abandon also accept a TASK_KEY after the ID."
        end
        target = task_target(update, task_id: task_id&.downcase)
        loop_id = target["loop_id"] || raise(Rho::Error, "This task has not started. Use /queue for waiting requests.")
        workspace_id = target.fetch("workspace_public_id")
        if %w[resume retry abandon].include?(action) && (refusal = execution_control_refusal(update, loop_id, workspace_id))
          return refusal
        end

        control do
          @bridge.execution_control(action, loop_id, workspace_public_id: workspace_id, **{ task_key: task_key }.compact)
          "Task #{action} accepted. Use /status to read its state."
        end
      end

      def execution_transcript(update, argument)
        tokens = argument.split(/\s+/)
        task_id = tokens.shift if tokens.first && Rho::Gateway::Commands::TASK_ID.match?(tokens.first)
        fields = {}
        tokens.each_slice(2) do |action, value|
          unless %w[before branch].include?(action) && value && !fields.key?(action == "branch" ? :prefix : :before)
            return "Use /transcript [TASK_ID] [branch PREFIX] [before CURSOR]."
          end
          fields[action == "branch" ? :prefix : :before] = value
        end
        target = task_target(update, task_id: task_id&.downcase)
        loop_id = target["loop_id"] || raise(Rho::Error, "This task has not started.")
        document = @bridge.transcript(loop_id, workspace_public_id: target.fetch("workspace_public_id"), **fields)
        text = "Execution transcript:\n#{Render.preview(JSON.pretty_generate(document), limit: 12_000)}"
        if document["has_older"] && document["next_before"]
          id = target["variant_id"] || target["input_id"]
          branch = fields[:prefix] ? " branch #{fields.fetch(:prefix)}" : ""
          text += "\nOlder rounds: /transcript #{id}#{branch} before #{document.fetch("next_before")}"
        end
        text
      end

      def search_sessions(update, argument)
        route = room(update)
        saved = route["history_search"]
        if argument == "next"
          return "No search continuation is saved. Use /search TEXT." unless saved
        else
          return "Use /search TEXT or /search next." if argument.strip.empty?

          workspaces = route.fetch("conversations").reject { |_id, row| row["side_parent"] }
            .values.map { |row| row.fetch("workspace_public_id") }.uniq
          saved = { "query" => argument, "workspaces" => workspaces, "after" => nil }
        end
        workspace_id = saved.fetch("workspaces").first
        return "No conversations are saved in this chat/topic." unless workspace_id

        page = @bridge.search_conversations(query: saved.fetch("query"), after: saved["after"], workspace_public_id: workspace_id)
        allowed = route.fetch("conversations").select { |_id, row| row["workspace_public_id"] == workspace_id && !row["side_parent"] }
        rows = page.fetch("matches").select { |row| allowed.key?(row.fetch("conversation_public_id")) }
        next_after = page.fetch("pagination")["next_after"]
        saved = saved.merge("after" => next_after,
          "workspaces" => next_after ? saved.fetch("workspaces") : saved.fetch("workspaces").drop(1))
        edit_room(update) { |room| room["history_search"] = saved.fetch("workspaces").empty? ? nil : saved }
        lines = rows.map do |row|
          "#{row["title"] || "Untitled conversation"}\n#{row.fetch("conversation_public_id")}" \
            "#{row["position"] ? " · turn #{row.fetch("position")}" : ""}\n#{row["excerpt"]}"
        end
        text = lines.empty? ? "No matches from this chat/topic in this search window." : "Matches in this chat/topic:\n#{lines.join("\n\n")}"
        text += "\nUse /search next for the next search window." unless saved.fetch("workspaces").empty?
        text
      end

      private

        def selected_conversation(update, reference: nil)
          route = room(update)
          if !owner?(update) && route.fetch("owner_id", update.user_id) != update.user_id
            raise Rho::Error, "Only this conversation's requester or the bot owner can control it."
          end
          pending = @state.read.fetch("pending_update")
          id = reference || pending["conversation_id"] || route["current"] || raise(Rho::Error, "No conversation is open. Use /sessions or /new.")
          tracker = route.fetch("conversations")[id] || raise(Rho::Error, "That conversation is not available in this chat/topic.")
          workspace_id = tracker.fetch("workspace_public_id")
          @state.change { |document| document.fetch("pending_update").merge!("conversation_id" => id, "workspace_public_id" => workspace_id) }
          [id, workspace_id]
        end

        def history_command(update, id, workspace_id, argument)
          action, value, extra = argument.split(/\s+/, 3)
          if action.nil? || action == "before"
            position = Integer(value, exception: false) if value
            return "Use /history or /history before POSITION." if extra || (action && (!position || position < 0))

            page = @bridge.history(id, before_position: position, workspace_public_id: workspace_id)
            lines = page.fetch("turns").map do |turn|
              "Turn #{turn.fetch("position")} · #{turn.fetch("public_id")}\n" \
                "#{[turn["prompt"], turn["content"], turn["steers"]].compact.join("\n")}"
            end
            text = lines.empty? ? "No visible history in this window." : lines.join("\n\n")
            if page.fetch("pagination")["has_older"]
              text += "\n\nOlder history: /history before #{page.fetch("pagination").fetch("before_position")}"
            end
            text
          elsif %w[hide show exclude include delete restore].include?(action) && value && !extra
            fields = case action
            when "hide" then { visibility: "hidden" }
            when "show", "include" then { visibility: "visible" }
            when "exclude" then { visibility: "excluded_from_context" }
            when "delete" then { concealed: true }
            when "restore" then { concealed: false }
            else raise Rho::Error, "Unknown history visibility."
            end
            control do
              @bridge.turn_view_state(id, value, workspace_public_id: workspace_id, **fields)
              "History #{action} applied to #{value}. This changes view state; content is retained."
            end
          else
            "Use /history [before POSITION] or /history hide|show|exclude|include|delete|restore TURN_ID."
          end
        end

        def history_control(update, id, workspace_id, action, argument)
          reference, value = argument.split(/\s+/, 2)
          if (%w[variants variant edit].include?(action) && !reference) ||
              (%w[variant edit].include?(action) && value.to_s.empty?) ||
              (%w[fork regenerate variants undo].include?(action) && value) || (action == "undo" && reference)
            return "Use /#{action} as shown in /help."
          end
          turn = frozen_history_turn(id, workspace_id, reference)
          turn_id = turn.fetch("public_id")
          case action
          when "variants"
            rows = @bridge.variants(id, turn_id, workspace_public_id: workspace_id)
            "Candidates for turn #{turn.fetch("position")}:\n" + rows.map { |row|
              "#{row.fetch("public_id")} · #{row.fetch("status")}#{row["active"] ? " [active]" : ""}\n#{Render.preview(row["content"].to_s, limit: 500)}"
            }.join("\n\n")
          when "fork"
            fork_history(update, id, workspace_id, turn)
          when "regenerate"
            loop_id = turn.dig("active_variant", "agent_loop_public_id")
            unless owner?(update)
              unless @bridge.isolated_history_turn?(turn)
                return "This turn may use the bot owner's personal memory. Start a new request or ask the bot owner to regenerate it."
              end
              if !loop_id || (refusal = execution_control_refusal(update, loop_id, workspace_id))
                return refusal || "This turn has no verified read-only execution. Ask the bot owner to regenerate it."
              end
            end
            change_candidate(update, id, workspace_id, turn) do
              result = @bridge.regenerate(id, turn_id, workspace_public_id: workspace_id)
              raise Rho::Error, "Regeneration refused: #{result.dig("world", "door_refused")}" unless result["variant"]

              ["Regeneration started. The new answer will be delivered here. Files were kept.", result.fetch("variant")]
            end
          when "variant"
            variant_id, view, extra = value.split(/\s+/, 3)
            return "Use /variant POSITION ID [hide|restore]." if extra || (view && !%w[hide restore].include?(view))
            if view
              return control do
                @bridge.candidate_view_state(id, turn_id, variant_id, concealed: view == "hide", workspace_public_id: workspace_id)
                "Candidate #{view == "hide" ? "hidden" : "restored"}."
              end
            end

            change_candidate(update, id, workspace_id, turn, expected_variant: value) do
              variant = @bridge.activate_variant(id, turn_id, value, workspace_public_id: workspace_id)
              ["Candidate selected. Its answer will be delivered here.", variant.fetch("public_id")]
            end
          when "edit"
            change_candidate(update, id, workspace_id, turn) do
              variant = @bridge.edit_turn(id, turn_id, text: value, workspace_public_id: workspace_id)
              ["Edited as a new candidate. The original remains in /variants.", variant.fetch("public_id")]
            end
          when "undo"
            control do
              @bridge.delete_turn(id, turn_id, workspace_public_id: workspace_id)
              "Newest turn deleted. Files were kept."
            end
          else
            raise Rho::Error, "Unknown history control."
          end
        end

        def frozen_history_turn(id, workspace_id, reference)
          pending = @state.read.fetch("pending_update")
          return pending.fetch("history_turn") if pending["history_turn"]

          turn = @bridge.history_turn(id, reference: reference, workspace_public_id: workspace_id)
          raise Rho::Error, "No turn at that position. Use /history to choose a turn." unless turn

          reference = turn.slice("public_id", "position", "answering_user_public_id").merge("active_variant" =>
            turn.fetch("active_variant", {}).slice("public_id", "agent_loop_public_id", "memory_context"))
          @state.change { |document| document.fetch("pending_update")["history_turn"] = reference }
          reference
        end

        def fork_history(update, id, workspace_id, turn)
          key = update_key(update, "fork")
          @state.change { |document| document.fetch("pending_update")["fork_key"] ||= key }
          result = @bridge.fork_conversation(id, turn.fetch("public_id"),
            idempotency_key: @state.read.fetch("pending_update").fetch("fork_key"), workspace_public_id: workspace_id)
          child = result.fetch("conversation")
          @bridge.attach(child, workspace_public_id: workspace_id)
          text = "Forked conversation #{child}. This chat now continues there. Files were kept."
          @state.change do |document|
            route = document.fetch("routes").fetch(update.route_key)
            route.fetch("conversations")[child] ||= { "position" => result.fetch("position"), "workspace_public_id" => workspace_id }
            route.merge!("current" => child, "workspace_public_id" => workspace_id)
            document.fetch("pending_update").merge!("conversation_id" => child, "control_status" => "applied", "control_result" => text)
          end
          discard_media(update.route_key)
          text
        end

        def change_candidate(update, id, workspace_id, turn, expected_variant: nil)
          known_variants = @bridge.variants(id, turn.fetch("public_id"), workspace_public_id: workspace_id).map { |row| row.fetch("public_id") }
          turn_id = turn.fetch("public_id")
          watch_key = "#{turn_id}:#{update.id}"
          watch = nil
          @state.change do |document|
            route = document.fetch("routes").fetch(update.route_key)
            tracker = route.fetch("conversations").fetch(id)
            tracker["candidate_watches"] ||= {}
            watch = {
              "turn_id" => turn_id, "position" => turn.fetch("position"), "previous_variant" => turn.dig("active_variant", "public_id"),
              "variant_id" => expected_variant, "known_variants" => known_variants,
              "owner_id" => route.fetch("owner_id", update.user_id), "room_key" => update.room_key,
              "message_id" => update.message["message_id"],
            }
            tracker.fetch("candidate_watches")[watch_key] = watch
          end
          @history_reads.delete(id)
          control do
            # Until the write is known to have succeeded, both it and any earlier
            # candidate need observation. A lost reply must not erase either one.
            begin
              text, variant = yield
            rescue Rho::ConnectionError
              raise
            rescue Rho::Core::Refused => error
              clear_candidate_watch(update.route_key, id, watch_key, watch) if error.status < 500
              raise
            rescue Rho::Error
              clear_candidate_watch(update.route_key, id, watch_key, watch)
              raise
            end
            @state.change do |document|
              watches = document.fetch("routes").dig(update.route_key, "conversations", id, "candidate_watches")
              if watches
                if variant == watch["previous_variant"]
                  watches.delete(watch_key)
                else
                  watches.delete_if { |key, row| row.fetch("turn_id", key) == turn_id }
                  watches[turn_id] = watch.merge("variant_id" => variant)
                end
              end
            end
            candidate = @bridge.variants(id, turn.fetch("public_id"), workspace_public_id: workspace_id)
              .find { |row| row.fetch("public_id") == variant }
            if candidate && candidate["agent_loop_public_id"]
              watch = { "owner_id" => room(update).fetch("owner_id", update.user_id), "room_key" => update.room_key,
                "message_id" => update.message["message_id"] }
              key = register_candidate_request(update.route_key, id, workspace_id, turn.fetch("public_id"), candidate, watch)
              @state.change { |document| document.fetch("pending_update")["candidate_request_id"] = key }
              text += "\nTask: #{variant}"
            end
            text
          end
        end
    end
  end
end
