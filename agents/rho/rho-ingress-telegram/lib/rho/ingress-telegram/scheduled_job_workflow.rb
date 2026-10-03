require "rho/scheduled_job_commands"
require_relative "scheduled_job_tracking"

module Rho
  module IngressTelegram
    module ScheduledJobWorkflow
      include ScheduledJobTracking

      def job_command(update, argument)
        raise Rho::Error, "/job accepts text only." if update.media || update.unsupported_media?

        command = saved_job_command(argument)
        if command.id && !Rho::Gateway::Commands::TASK_ID.match?(command.id)
          raise Rho::Error, "Use the full scheduled job ID from /job list."
        end
        return create_scheduled_job(update, command) if command.action == "create"

        binding = command.id ? scheduled_job_binding(update, command.id) : current_job_binding(update)
        if %w[edit resume].include?(command.action) && !owner?(update)
          row = @bridge.scheduled_job(binding.fetch("conversation_id"), command.id,
            workspace_public_id: binding.fetch("workspace_public_id"))
          unless @bridge.read_only_scheduled_job?(row)
            raise Rho::Error, "This scheduled job no longer has a verified read-only profile and tool set. Ask the bot owner to edit or resume it."
          end
        end
        execute = lambda do
          result = @bridge.scheduled_job_command(binding.fetch("conversation_id"), command: command,
            workspace_public_id: binding.fetch("workspace_public_id"))
          render_job_command(command, result, update: update, conversation_id: binding.fetch("conversation_id"))
        end
        text = %w[edit pause resume cancel].include?(command.action) ? control(&execute) : execute.call
        reply(update, text)
      end

      private

        def saved_job_command(argument)
          saved = @state.read.fetch("pending_update")["scheduled_job_command"]
          if saved
            return Rho::ScheduledJobCommands::Command.new(action: saved.fetch("action"), id: saved["id"],
              fields: saved.fetch("fields").transform_keys(&:to_sym))
          end

          command = Rho::ScheduledJobCommands.parse(argument, now: @clock.call)
          @state.change do |document|
            document.fetch("pending_update")["scheduled_job_command"] = {
              "action" => command.action, "id" => command.id&.downcase, "fields" => command.fields,
            }
          end
          command.with(id: command.id&.downcase)
        end

        def current_job_binding(update)
          id = open_route(update)
          route = room(update)
          tracker = route.fetch("conversations").fetch(id)
          raise Rho::Error, "Scheduled jobs belong to the main conversation. Return with /main first." if tracker["side_parent"]

          { "owner_id" => route.fetch("owner_id", update.user_id), "route_key" => update.route_key,
            "room_key" => update.room_key, "message_id" => update.message["message_id"],
            "conversation_id" => id, "workspace_public_id" => workspace_for(route, id) }
        end

        def scheduled_job_binding(update, job_id)
          binding = @state.read.fetch("job_bindings")[job_id]
          unless binding
            current = current_job_binding(update)
            route = room(update)
            discover_scheduled_jobs(current.fetch("route_key"), current.fetch("conversation_id"),
              route.fetch("conversations").fetch(current.fetch("conversation_id")))
            binding = @state.read.fetch("job_bindings")[job_id]
          end
          unless binding && binding.fetch("room_key") == update.room_key
            raise Rho::Error, "That scheduled job is not available in this chat/topic. Use /job list."
          end
          unless owner?(update) || binding.fetch("owner_id") == update.user_id
            raise Rho::Error, "Only this job's requester or the bot owner can manage it."
          end
          route = @state.read.fetch("routes").fetch(binding.fetch("route_key"))
          workspace_for(route, binding.fetch("conversation_id"))
          binding
        end

        def create_scheduled_job(update, command)
          pending = @state.read.fetch("pending_update")
          saved = pending["scheduled_job_create"]
          unless saved
            binding = current_job_binding(update)
            route = room(update)
            policy = { "model" => pending["model"], "speaker_actor_public_id" => speaker_for(update),
              "to" => @bridge.scheduled_job_answerer(isolated: !owner?(update)),
              "tool_names" => input_tool_names(user_id: update.user_id, group: route.fetch("group"),
                route_key: update.route_key, conversation_id: binding.fetch("conversation_id")) }
            saved = { "binding" => binding, "policy" => policy }
            @state.change { |document| document.fetch("pending_update")["scheduled_job_create"] = saved }
          end
          binding = saved.fetch("binding")
          row = @bridge.scheduled_job_command(binding.fetch("conversation_id"), command: command,
            workspace_public_id: binding.fetch("workspace_public_id"),
            idempotency_key: update_key(update, "scheduled-job"), **saved.fetch("policy").transform_keys(&:to_sym))
          text = "#{Rho::ScheduledJobCommands.render(command, row)}\nRuns independently; results return to this conversation. " \
            "Use /job history #{row.fetch("public_id")} for execution task IDs."
          @state.change do |document|
            document.fetch("job_bindings")[row.fetch("public_id")] ||= binding
            document.fetch("pending_update").merge!("control_status" => "applied", "control_result" => text)
          end
          reply(update, text)
        end

        def render_job_command(command, result, update:, conversation_id:)
          if command.action == "list"
            adopt_scheduled_jobs(result.fetch("scheduled_jobs"), conversation_id: conversation_id)
            result = result.merge("scheduled_jobs" => result.fetch("scheduled_jobs").select do |row|
              binding = @state.read.fetch("job_bindings")[row.fetch("public_id")]
              !binding || (binding.fetch("room_key") == update.room_key && (owner?(update) || binding.fetch("owner_id") == update.user_id))
            end)
          elsif command.action == "history"
            binding = @state.read.fetch("job_bindings").fetch(command.id)
            record_scheduled_executions(command.id, binding, result.fetch("executions"))
            lines = result.fetch("executions").map do |row|
              "Task: #{row.fetch("input_public_id")} · #{row["status"] || "pending"} · #{row.fetch("scheduled_for")}"
            end
            lines << "More: /job history #{command.id} #{result.dig("pagination", "next_after")}" if result.dig("pagination", "next_after")
            return lines.empty? ? "No executions yet." : lines.join("\n")
          end
          Rho::ScheduledJobCommands.render(command, result)
            .gsub("More jobs: list ", "More jobs: /job list ")
        end
    end
  end
end
