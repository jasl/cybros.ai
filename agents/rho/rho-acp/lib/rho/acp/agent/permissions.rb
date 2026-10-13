require "securerandom"

module Rho
  module Acp
    class Agent
      # THE PARK, THE ASK, CANCEL.
      #
      # THE PARK (`attention_required {approval_required, blocked_task_keys}`,
      # through `TurnFollow`'s `on_park`): the keys are handed to a PARK
      # THREAD at once — the follow goes on reading the stream, the
      # person takes their time — and there, per key, sequentially, the
      # `tool_call` already out, `session/request_permission
      # {toolCall, options}` with the three options: `allow` →
      # `Core#approve(loop, key)`; `always` → `approve(…, always: true)`
      # (the session grant: exact command/path for process/file writes,
      # the site for `web_fetch`, whole tool otherwise; `rho rules` lists
      # it); `reject` → `deny(…, reason:
      # "rejected in <clientInfo.name>")`; `cancelled` → nothing (the stop
      # cascades; a deny racing a cancel is a refusal to log); -32800 or a
      # closed socket → `deny(reason: "the client went away")` — unless a
      # `session/cancel` is what cancelled it, which is the cascade's own.
      # A key the daemon refuses (decided elsewhere) is dropped silently.
      # `reject_always` is not offered: a standing deny is the person's
      # `rho rules`, not a click. Under `bypass` no park; under `ask` reads
      # and kernel tools run and every effect parks; under `rules` a call
      # no rule allows is refused as data — a `failed` tool call, no request.
      #
      # THE ASK (`awaiting_human`, the task's `prompt`): with
      # `elicitation.form` → `elicitation/create {sessionId, mode: form,
      # message, requestedSchema {answer}}` → `accept` → `Core#answer(loop,
      # key, content.answer)` and the follow continues on the same turn
      # (`:continue`); `decline` → `answer(…, outcome: "failed")`; `cancel`
      # → held (`:hold`). Without the form: the question is streamed as an
      # `agent_message_chunk`, the prompt answers `end_turn` and `[loop,
      # key]` is held; the NEXT `session/prompt` is `Core#answer` on it (a
      # documented limitation: a changed subject becomes the answer; the
      # escape is `session/cancel`, which stops the turn and drops the hold).
      #
      # CANCEL (`session/cancel`): `cancel_requested` set (the dispatcher,
      # in wire order); `$/cancel_request` for every outstanding request
      # this surface issued on the session and their -32800 answers
      # consumed by the threads waiting on them; the held ask dropped;
      # `Core#stop(session, force: true)` with every refusal rescued (a
      # cancel with nothing in flight is a no-op); the prompt answers
      # `cancelled` once the stream's last frame landed — never an error,
      # whatever `stop` raised.
      class Permissions
        OPTIONS = [
          { "optionId" => "allow", "name" => "Allow", "kind" => Acp::Methods::PermissionOptionKind::ALLOW_ONCE },
          { "optionId" => "always", "name" => "Always allow — rho remembers this call's shape until its daemon restarts",
            "kind" => Acp::Methods::PermissionOptionKind::ALLOW_ALWAYS },
          { "optionId" => "reject", "name" => "Reject", "kind" => Acp::Methods::PermissionOptionKind::REJECT_ONCE },
        ].freeze
        WENT_AWAY = "the client went away".freeze
        ANSWER_SCHEMA = {
          "type" => "object", "properties" => { "answer" => { "type" => "string" } }, "required" => ["answer"],
        }.freeze

        # The cascade, from the dispatcher's thread.
        def self.cancel(agent, session, core)
          session.request_cancel!
          session.cancel_outstanding
          session.held = nil
          begin
            core.stop(session.id, force: true)
          rescue Rho::Error => error
            agent.say("cancel: #{error.message}")
          end
          nil
        end

        def initialize(agent:, session:, core:, mapping:)
          @agent = agent
          @session = session
          @core = core
          @mapping = mapping
        end

        # `TurnFollow`'s `on_park`: answers at once, the keys go to a thread.
        def park(run_public_id, keys)
          Thread.new { keys.each { |key| decide(run_public_id, key) } }.tap { |thread| thread.name = "rho-acp-park" }
          nil
        end

        # One key, one request, one verb.
        def decide(run_public_id, key)
          pending = @agent.connection.request(Acp::Methods::SESSION_REQUEST_PERMISSION,
            permission_request(run_public_id, key))
          result = @session.track(pending) { pending.wait }
          act(run_public_id, key, Hash.try_convert(result) || {})
        rescue RemoteError => error
          return if error.code == Acp::Methods::ErrorCode::REQUEST_CANCELLED && @session.cancel_requested?

          deny(run_public_id, key, WENT_AWAY)
        rescue Closed
          deny(run_public_id, key, WENT_AWAY)
        rescue Rho::Error => error
          @agent.say("park #{key}: #{error.message}")
        end

        # THE ASK: `:continue` when the turn goes on, `:hold` when the next
        # prompt answers it.
        def ask(run_public_id, key)
          return ask_held(run_public_id, key) unless @agent.client.elicitation_form?

          prompt = question(run_public_id, key)
          pending = @agent.connection.request(Acp::Methods::ELICITATION_CREATE,
            "sessionId" => @session.id, "elicitationId" => SecureRandom.hex(8), "mode" => "form", "message" => prompt,
            "requestedSchema" => ANSWER_SCHEMA)
          result = Hash.try_convert(@session.track(pending) { pending.wait }) || {}
          case result["action"]
          when Acp::Methods::ElicitationAction::ACCEPT
            @core.answer(run_public_id, key, Hash.try_convert(result["content"])&.dig("answer").to_s)
            :continue
          when Acp::Methods::ElicitationAction::DECLINE
            @core.answer(run_public_id, key, "", outcome: "failed")
            :continue
          else :hold
          end
        rescue RemoteError, Closed
          :hold
        end

        # THE ASK HELD WITHOUT THE FORM, whatever the client advertised: the
        # question streamed as the reply's last chunk, `:hold` — the ask's
        # own way for a client without the form, and the re-arm's fallback
        # when the session's slot is already a prompt's (`Rearm`).
        def ask_held(run_public_id, key) = hold_without_form(question(run_public_id, key))

        private

          def hold_without_form(prompt)
            @mapping.question(prompt)
            :hold
          end

          def question(run_public_id, key)
            @core.task(run_public_id, key)["prompt"].to_s
          rescue Rho::Error => error
            @agent.say("the ask #{key} could not be read (#{error.message})")
            ""
          end

          # The call as the mapping remembered it, else one read. Core
          # derives the grant; the option only explains its scope.
          def permission_request(run_public_id, key)
            row = @mapping.state.tasks[key]
            if row.nil?
              detail = begin
                @core.task(run_public_id, key)
              rescue Rho::Error
                {}
              end
              name = detail["tool_name"].to_s
              input = Hash.try_convert(detail["tool_input"]) || {}
              row = ToolCall.new(title: name.empty? ? key : name, kind: Mapping.kind_of(name), input: input,
                status: "needs_approval", tool_name: name)
            end
            {
              "sessionId" => @session.id,
              "toolCall" => { "toolCallId" => "#{run_public_id}:#{key}", "title" => row.title, "kind" => row.kind, "rawInput" => row.input },
              "options" => options_for(row.tool_name),
            }
          end

          def options_for(tool_name)
            return OPTIONS unless tool_name == "web_fetch"

            OPTIONS.map do |option|
              if option["optionId"] == "always"
                option.merge("name" => "Allow this site until rho restarts")
              else
                option
              end
            end
          end

          def act(run_public_id, key, result)
            outcome = Hash.try_convert(result["outcome"]) || {}
            return if outcome["outcome"] == Acp::Methods::PermissionOutcome::CANCELLED

            case outcome["optionId"]
            when "allow" then @core.approve(run_public_id, key)
            when "always" then @core.approve(run_public_id, key, always: true)
            when "reject" then @core.deny(run_public_id, key, reason: "rejected in #{@agent.client.name}")
            else @agent.say("park #{key}: the client answered no option (#{result.inspect})")
            end
          end

          def deny(run_public_id, key, reason)
            @core.deny(run_public_id, key, reason: reason)
          rescue Rho::Error => error
            @agent.say("park #{key}: #{error.message}")
          end
      end
    end
  end
end
