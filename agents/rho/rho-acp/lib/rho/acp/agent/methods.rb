module Rho
  module Acp
    class Agent
      # THE METHOD TABLE, client → agent, dispatched
      # off the connection's drain: every REQUEST on a thread of its own
      # (a kernel round-trip never delays another session's cancel), each
      # answered once — the handler's document, or the `Refusal` it raised
      # translated to the JSON-RPC error; a notification on the drain
      # thread for the flag it sets and a thread for the rest. `_method`
      # requests and the methods this agent has no capability for
      # (`session/list`, `session/delete`, `logout`, `session/fork`,
      # `providers/*`, `mcp/*`, `nes/*`, `document/*`) are -32601;
      # unknown notifications are ignored (the extensibility page).
      #
      # `$/cancel_request` never reaches here: the connection marks the
      # inbound and fires its `on_cancel` hooks — a `session/prompt`'s
      # hook runs the cancel path (the prompt answers `cancelled`), a
      # `session/load`'s aborts the replay (-32800), any other request
      # still running answers -32800 once its handler returns.
      module Methods
        class Dispatcher
          TABLE = {
            Acp::Methods::INITIALIZE => :initialize_agent,
            Acp::Methods::AUTHENTICATE => :authenticate,
            Acp::Methods::SESSION_NEW => :session_new,
            Acp::Methods::SESSION_LOAD => :session_load,
            Acp::Methods::SESSION_RESUME => :session_resume,
            Acp::Methods::SESSION_CLOSE => :session_close,
            Acp::Methods::SESSION_SET_MODE => :session_set_mode,
            Acp::Methods::SESSION_SET_CONFIG_OPTION => :session_set_config_option,
            Acp::Methods::SESSION_PROMPT => :session_prompt,
          }.freeze

          def initialize(agent)
            @agent = agent
          end

          def dispatch(event)
            case event
            when Connection::Inbound then request(event)
            when Wire::Notification then notification(event)
            else nil
            end
          end

          private

            # THE ONE PROMPT PER SESSION is claimed HERE, on the drain, in
            # wire order — a second prompt while one runs is -32600 before
            # any thread starts; the claim is released when the turn ends.
            def request(inbound)
              handler = TABLE[inbound.method]
              return refuse(inbound, Refusal.method_not_found(inbound.method)) if handler.nil?

              if handler == :session_prompt
                session = session_of(inbound.params)
                return refuse(inbound, Refusal.not_found("unknown session #{id_of(inbound.params).inspect}")) if session.nil?
                return refuse(inbound, Refusal.invalid_request("a prompt is already running on #{session.id}")) unless
                  session.claim_prompt(inbound)
              end
              Thread.new { serve(inbound, handler) }.tap { |thread| thread.name = "rho-acp-#{inbound.method}" }
              nil
            end

            def serve(inbound, handler)
              result = send(handler, inbound)
              return if inbound.answered?

              inbound.cancelled? ? inbound.fail_cancelled : inbound.respond(result)
            rescue StandardError => error
              return if inbound.answered?

              refuse(inbound, Errors.translate(error))
            end

            def refuse(inbound, error)
              inbound.fail(error.code, error.message, data: error.data)
              nil
            end

            # `session/cancel`: the flag lands on the drain thread,
            # in wire order; the cascade runs on its own.
            def notification(frame)
              return unless frame.method == Acp::Methods::SESSION_CANCEL

              session = session_of(frame.params)
              return if session.nil?

              session.request_cancel!
              Thread.new { Permissions.cancel(@agent, session, @agent.core) }.tap { |thread| thread.name = "rho-acp-cancel" }
              nil
            end

            def id_of(params) = Hash.try_convert(params)&.dig("sessionId")

            def session_of(params)
              id = id_of(params)
              id.is_a?(String) ? @agent.sessions[id] : nil
            end

            # The session a request names, or -32002; a session whose
            # conversation ended under the follow is -32002 for good.
            def session!(inbound)
              session = session_of(inbound.params)
              raise Refusal.not_found("unknown session #{id_of(inbound.params).inspect}") if session.nil?
              raise Refusal.not_found("the conversation #{session.id} ended") if session.ended

              session
            end

            def params_of(inbound) = Hash.try_convert(inbound.params) || {}

            # ---- the table ----

            # `initialize`: no kernel call; the client's capabilities
            # remembered; any `protocolVersion` answered with 1 (the agent
            # answers its highest; only the client closes).
            def initialize_agent(inbound)
              @agent.client.remember(params_of(inbound))
              Auth.initialize_document(@agent)
            end

            def authenticate(inbound) = Auth.authenticate(@agent, @agent.core, params_of(inbound))

            # `session/new` → the open, the binds, the session; the
            # commands update AFTER the response line.
            def session_new(inbound)
              core = @agent.core
              session = Environment.open(@agent, core, params_of(inbound))
              @agent.sessions.add(session)
              inbound.respond({ "sessionId" => session.id }.merge(Options.document(@agent, session)))
              Commands.announce(@agent, session, core)
              nil
            end

            # `session/load`: the attach, the binds, the REPLAY before the
            # response, the commands update, then a held ask re-armed.
            def session_load(inbound)
              core = @agent.core
              session = Environment.load(@agent, core, params_of(inbound))
              @agent.sessions.add(session)
              Replay.call(@agent, session, core, inbound)
              inbound.respond(Options.document(@agent, session))
              Commands.announce(@agent, session, core)
              Replay.rearm(@agent, session, core)
              nil
            end

            # `session/resume`: load without the replay.
            def session_resume(inbound)
              core = @agent.core
              session = Environment.load(@agent, core, params_of(inbound))
              @agent.sessions.add(session)
              inbound.respond(Options.document(@agent, session))
              Commands.announce(@agent, session, core)
              nil
            end

            # `session/close`: the in-process session dropped (its live
            # members released); the daemon keeps following.
            def session_close(inbound)
              session = session!(inbound)
              @agent.sessions.delete(session.id)
              Environment.release(@agent, session)
              {}
            end

            def session_set_mode(inbound)
              session = session!(inbound)
              Options.set_mode(session, params_of(inbound)["modeId"])
              {}
            end

            def session_set_config_option(inbound)
              session = session!(inbound)
              params = params_of(inbound)
              Options.set_config_option(@agent, @agent.core, session, params["configId"], params["value"])
              { "configOptions" => Options.config_options(@agent, session) }
            end

            # The prompt turn, on this thread, answered by `Turn`.
            def session_prompt(inbound)
              session = session_of(inbound.params)
              Turn.new(@agent, session, inbound, @agent.core).call
              nil
            end
        end
      end
    end
  end
end
