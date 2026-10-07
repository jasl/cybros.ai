module Rho
  module Acp
    class Agent
      # SLASH COMMANDS: `available_commands_update
      # {availableCommands}` after `session/new`/`load`/`resume` — three
      # SURFACE commands, `retry` (`Core#retry(loop)` on the holding turn,
      # then the same turn re-followed), `abandon` (`Core#abandon`),
      # `compact` (`Core#compact(session)`) — followed by the skills
      # (`Core#skills`' user, workspace and project rows as `{name,
      # description}`). A `/skill-name …` prompt is posted VERBATIM: the
      # model holds the `skill` tool and the roster; no rewriting in the
      # surface. No `/mode`, `/model`: `set_mode`/`set_config_option` are
      # the doors.
      module Commands
        SURFACE = {
          "retry" => "Retry the holding turn (the turn failed and the loop is holding)",
          "abandon" => "Abandon the holding turn",
          "compact" => "Compact the conversation now",
        }.freeze
        WORD = %r{\A/([A-Za-z0-9_-]+)(?:\s|\z)}

        module_function

        # The surface command a prompt's leading `/word` names, else nil
        # (any other `/word` is the model's).
        def surface_word(text)
          word = text.to_s[WORD, 1]
          SURFACE.key?(word) ? word : nil
        end

        # Runs the command; answers the PromptResponse (`/retry` through
        # the turn's own follow, once the follower saw the turn reopen —
        # `Turn.catch_up`: a re-follow that beat the kernel's `running`
        # would answer the old hold to a retry that took).
        def run(agent, session, core, word, turn)
          case word
          when "retry"
            run_id = target(session, core)
            raise Refusal.internal("no turn to retry on #{session.id}") if run_id.nil?

            core.retry(run_id)
            Turn.catch_up(core, session) { |row| row["status"] != "failed" }
            turn.follow(session.last_turn, run_id, variant: session.last_variant)
          when "abandon"
            run_id = target(session, core)
            raise Refusal.internal("no turn to abandon on #{session.id}") if run_id.nil?

            core.abandon(run_id)
            { "stopReason" => Acp::Methods::StopReason::END_TURN }
          when "compact"
            core.compact(session.id)
            { "stopReason" => Acp::Methods::StopReason::END_TURN }
          else raise Refusal.internal("unknown surface command #{word.inspect}")
          end
        end

        def target(session, core)
          Replay.restore(session, core) if session.last_turn.nil?
          session.last_loop
        end

        # The roster: the three, then the skills on their rungs.
        def roster(agent, core)
          SURFACE.map { |name, description| { "name" => name, "description" => description } } + skills(agent, core)
        end

        def skills(agent, core)
          document = core.skills
          %w[user workspace project].flat_map do |rung|
            Array(document[rung]).filter_map do |row|
              row = Hash.try_convert(row)
              name = String.try_convert(row&.fetch("name", nil))
              next if name.nil? || name.empty?

              { "name" => name, "description" => row["description"].to_s }
            end
          end
        rescue Rho::Error => error
          agent.say("the skills could not be listed (#{error.message})")
          []
        end

        # The notification, after the response line.
        def announce(agent, session, core)
          agent.connection.notify(Acp::Methods::SESSION_UPDATE,
            "sessionId" => session.id,
            "update" => {
              Acp::Methods::SESSION_UPDATE_DISCRIMINATOR => Acp::Methods::SessionUpdate::AVAILABLE_COMMANDS_UPDATE,
              "availableCommands" => roster(agent, core),
            })
          nil
        rescue Closed
          nil
        end
      end
    end
  end
end
