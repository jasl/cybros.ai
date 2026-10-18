module Rho
  class Core
    # One Bot's conversation lifecycle. Reads never open a conversation;
    # mutations retain the caller's operation identity across retries.
    module Bots
      def bot_detail(agent_public_id:)
        bot_read("detail", agent_public_id: agent_public_id)
      end

      def bot_history(agent_public_id:, after: nil, limit: nil, archived: nil)
        bot_read("history", agent_public_id: agent_public_id, after: after, limit: limit, archived: archived)
      end

      def ensure_bot_current(agent_public_id:, operation_id:)
        bot_write("current", agent_public_id: agent_public_id, operation_id: operation_id)
      end

      def new_bot_conversation(agent_public_id:, operation_id:, home_workspace_public_id: BotSettings::KEEP)
        body = { agent_public_id: agent_public_id, operation_id: operation_id }
        body[:home_workspace_public_id] = home_workspace_public_id unless BotSettings::KEEP.equal?(home_workspace_public_id)
        bot_write("new", **body)
      end

      def resume_bot_conversation(agent_public_id:, operation_id:, conversation_public_id:, workspace_public_id:)
        bot_write("resume", agent_public_id: agent_public_id, operation_id: operation_id,
          conversation_public_id: conversation_public_id, workspace_public_id: workspace_public_id)
      end

      def fork_bot_conversation(agent_public_id:, operation_id:, conversation_public_id:, workspace_public_id:,
                                turn_public_id:, variant_public_id: nil)
        bot_write("fork", **{ agent_public_id: agent_public_id, operation_id: operation_id,
          conversation_public_id: conversation_public_id, workspace_public_id: workspace_public_id,
          turn_public_id: turn_public_id, variant_public_id: variant_public_id }.compact)
      end

      private

        def bot_read(action, **fields)
          response = get(require_daemon, "/bots/#{action}?#{URI.encode_www_form(fields.compact)}", budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to read the Bot") unless response.code.to_i == 200

          document
        end

        def bot_write(action, **fields)
          response = post(require_daemon, "/bots/#{action}", fields, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to switch the Bot conversation") unless response.code.to_i == 200

          document
        end
    end
  end
end
