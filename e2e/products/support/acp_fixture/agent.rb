# THE SCRIPTED ACP AGENT: a plain Ruby program — stdlib only, no bundle — that a client spawns and
# drives over stdio by the spec (the facts sheet: JSON-RPC 2.0, one object per line, UTF-8, stderr
# for logs, `PROTOCOL_VERSION` 1). Its own reader, writer and id space, on purpose independent of
# the gem's `Rho::Acp`, so the harness test pins two implementations of the framing against each
# other and `delegate_agent` has an agent whose every behaviour is chosen by argv:
#
# --mode plain echoes each prompt in two chunks of one messageId; `client?` and `session?` answer
# what the agent remembered of the handshake and the session --mode permission per prompt line `run
# CMD` / `edit PATH` (else `run npm test`): a `tool_call`, a `session/request_permission` (allow /
# always / reject), the update and a word --mode id_only permission whose request carries the
# toolCallId alone --mode sleep `sleep N` (≤ 20): a `tick` chunk every half second; honours
# `session/cancel`; any other prompt is echoed as plain does --mode ignore_cancel sleep that ignores
# `session/cancel` and `$/cancel_request` (bounded all the same) --mode die one chunk, then `exit!
# 3` mid-turn --mode auth_required `session/new` is -32000 until `authenticate {methodId:
# "fixture-login"}` --mode terminal_auth_only one terminal-type auth method; `session/new` is -32000
# for good --mode elicit a form `elicitation/create`; the answer, or the action, becomes the text
# --mode model_option a `model` config option; `set_config_option` moves it; the text names it
# --protocol-version N the version `initialize` answers (1 by default)
#
# Every mode: -32602 for a relative cwd, -32002 for an unknown session,
# -32600 for a second prompt on a busy session, -32601 for a method it
# does not serve (custom ones included), a custom notification ignored,
# -32700 / -32600 for a bad line, `session/close` served, `$/cancel_request`
# on a running prompt answered -32800, and — when `session/cancel` lands
# while its own permission or elicitation request is outstanding — the
# cascade: `$/cancel_request` for that request, the client's answer
# consumed (bounded), then `cancelled`. A `cancelled` permission outcome
# is taken as the spec's word that a `session/cancel` is on its way, and
# waited for (bounded) before the turn goes on.
#
# THREADS: the main thread reads and dispatches — every table moves
# there, in wire order, so the cascade never races the client's answer —
# and each prompt turn runs on a thread of its own that polls the turn's
# flag; nothing raises into another thread (a `Thread#raise` under the
# write lock would tear a line).
require "json"
require "optparse"

module E2E
  module AcpFixture
    class Agent
      NAME = "acp-fixture-agent".freeze
      MAX_SLEEP_SECONDS = 20
      TICK_SECONDS = 0.5
      CASCADE_WAIT_SECONDS = 5
      CANCELLED_OUTCOME_WAIT_SECONDS = 1
      POLL_SECONDS = 0.02
      MODES = %w[plain permission id_only sleep ignore_cancel die auth_required terminal_auth_only elicit model_option].freeze

      # `cancelled` is nil,:cancelled (session/cancel) or:aborted ($/cancel_request on the prompt).
      Turn = Struct.new(:session, :request_id, :cancelled, :thread, :outstanding)

      def initialize(mode:, protocol_version:, input: STDIN, output: STDOUT, error: STDERR)
        raise ArgumentError, "unknown mode #{mode.inspect}; one of #{MODES.join(", ")}" unless MODES.include?(mode)

        @mode = mode
        @protocol_version = protocol_version
        @input = input
        @output = output
        @error = error
        @input.set_encoding(Encoding::UTF_8)
        @output.set_encoding(Encoding::UTF_8)
        @output.sync = true
        @write_lock = Mutex.new
        @lock = Mutex.new
        @sessions = {}
        @turns = {}
        @pending = {}
        @next_id = 0
        @session_count = 0
        @authenticated = false
        @handshake = nil
      end

      def run
        log "mode #{@mode}, protocol version #{@protocol_version}"
        while (line = @input.gets)
          handle_line(line)
        end
        @lock.synchronize { @turns.values.map(&:thread) }.compact.each { |thread| thread.join(1) }
        0
      end

      private

        def log(text)
          @error.puts "fixture agent: #{text}"
          @error.flush
        end

        # --- the wire -----------------------------------------------------

        def write(message)
          @write_lock.synchronize { @output.write("#{JSON.generate(message)}\n") }
        rescue IOError, Errno::EPIPE
          nil
        end

        def result(id, value) = write({ "jsonrpc" => "2.0", "id" => id, "result" => value })

        def failure(id, code, message)
          write({ "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } })
        end

        def notify(method, params) = write({ "jsonrpc" => "2.0", "method" => method, "params" => params })

        def update(session, body) = notify("session/update", { "sessionId" => session, "update" => body })

        def handle_line(line)
          return failure(nil, -32700, "Parse error") unless line.valid_encoding?

          text = line.strip
          return if text.empty?

          message = JSON.parse(text)
          return failure(nil, -32600, "Invalid Request") unless message.is_a?(Hash)

          dispatch(message)
        rescue JSON::ParserError
          failure(nil, -32700, "Parse error")
        end

        def dispatch(message)
          id = message["id"]
          method = message["method"]
          if method.is_a?(String)
            id.nil? ? notification(method, message["params"]) : request(id, method, message["params"] || {})
          elsif message.key?("result") || message["error"].is_a?(Hash)
            response(id, message)
          else
            failure(id.is_a?(Integer) || id.is_a?(String) ? id : nil, -32600, "Invalid Request")
          end
        end

        # --- inbound requests ---------------------------------------------

        def request(id, method, params)
          case method
          when "initialize" then initialize_agent(id, params)
          when "authenticate" then authenticate(id, params)
          when "session/new" then new_session(id, params)
          when "session/prompt" then prompt(id, params)
          when "session/close" then close_session(id, params)
          when "session/set_config_option" then set_config_option(id, params)
          else failure(id, -32601, "Method not found")
          end
        end

        def initialize_agent(id, params)
          @handshake = params
          result(id, {
            "protocolVersion" => @protocol_version,
            "agentInfo" => { "name" => NAME, "title" => "ACP fixture agent", "version" => "1" },
            "agentCapabilities" => {
              "loadSession" => false,
              "promptCapabilities" => { "image" => false, "audio" => false, "embeddedContext" => false },
              "mcpCapabilities" => { "http" => false, "sse" => false },
              "sessionCapabilities" => { "close" => {} },
            },
            "authMethods" => auth_methods,
          })
        end

        def auth_methods
          case @mode
          when "auth_required"
            [{ "id" => "fixture-login", "name" => "Fixture login", "description" => "Logs the fixture in" }]
          when "terminal_auth_only"
            [{ "id" => "login", "type" => "terminal", "name" => "Log in from the terminal", "args" => ["login"], "env" => [] }]
          else []
          end
        end

        def authenticate(id, params)
          unless @mode == "auth_required" && params["methodId"] == "fixture-login"
            return failure(id, -32602, "unknown auth method #{params["methodId"].inspect}")
          end

          @authenticated = true
          result(id, {})
        end

        def new_session(id, params)
          cwd = params["cwd"]
          return failure(id, -32602, "cwd must be an absolute path") unless cwd.is_a?(String) && cwd.start_with?("/")
          return failure(id, -32000, "Authentication required") if auth_gate?

          session = @lock.synchronize do
            @session_count += 1
            key = "fx-#{@session_count}"
            @sessions[key] = { "cwd" => cwd, "mcpServers" => Array(params["mcpServers"]).length, "model" => "fx-small" }
            key
          end
          document = { "sessionId" => session }
          document["configOptions"] = config_options(session) if @mode == "model_option"
          result(id, document)
        end

        def auth_gate? = (@mode == "auth_required" && !@authenticated) || @mode == "terminal_auth_only"

        def close_session(id, params)
          return failure(id, -32002, "unknown session") unless @lock.synchronize { @sessions.delete(params["sessionId"]) }

          result(id, {})
        end

        def config_options(session)
          current = @lock.synchronize { @sessions.fetch(session).fetch("model") }
          [{
            "id" => "model", "name" => "Model", "category" => "model", "type" => "select", "currentValue" => current,
            "options" => [{ "value" => "fx-small", "name" => "Fixture small" }, { "value" => "fx-large", "name" => "Fixture large" }],
          }]
        end

        def set_config_option(id, params)
          return failure(id, -32601, "Method not found") unless @mode == "model_option"

          session = params["sessionId"]
          return failure(id, -32002, "unknown session") unless @lock.synchronize { @sessions.key?(session) }
          return failure(id, -32602, "unknown config option #{params["configId"].inspect}") unless params["configId"] == "model"
          return failure(id, -32602, "unknown model #{params["value"].inspect}") unless %w[fx-small fx-large].include?(params["value"])

          @lock.synchronize { @sessions.fetch(session)["model"] = params["value"] }
          result(id, { "configOptions" => config_options(session) })
        end

        # --- the prompt turn ----------------------------------------------

        def prompt(id, params)
          session = params["sessionId"]
          return failure(id, -32002, "unknown session") unless @lock.synchronize { @sessions.key?(session) }

          turn = Turn.new(session, id, nil, nil, [])
          busy = @lock.synchronize do
            next true if @turns.key?(session)

            @turns[session] = turn
            false
          end
          return failure(id, -32600, "a prompt is already running on #{session}") if busy

          turn.thread = Thread.new { run_turn(turn, prompt_text(params)) }
        end

        def prompt_text(params)
          Array(params["prompt"]).filter_map { |block| block["text"] if block.is_a?(Hash) && block["type"] == "text" }.join("\n\n")
        end

        def run_turn(turn, text)
          words = turn_words(turn, text)
          case turn.cancelled
          when :aborted then failure(turn.request_id, -32800, "Request cancelled")
          when :cancelled
            say(turn, words) if words
            result(turn.request_id, { "stopReason" => "cancelled" })
          else
            say(turn, words) if words
            result(turn.request_id, { "stopReason" => "end_turn" })
          end
        ensure
          @lock.synchronize { @turns.delete(turn.session) if @turns[turn.session].equal?(turn) }
        end

        # The turn's closing words (nil when everything was said already).
        def turn_words(turn, text)
          case @mode
          when "permission", "id_only" then permission_turn(turn, text)
          when "sleep", "ignore_cancel" then sleep_turn(turn, text)
          when "die" then die_turn(turn)
          when "elicit" then elicit_turn(turn)
          when "model_option" then "model:#{@lock.synchronize { @sessions.fetch(turn.session).fetch("model") }}"
          else plain_turn(turn, text)
          end
        end

        def plain_turn(turn, text)
          case text
          when "client?" then JSON.generate(@handshake)
          when "session?" then JSON.generate(@lock.synchronize { @sessions.fetch(turn.session) })
          else
            say(turn, "echo: #{text}", split: true)
            nil
          end
        end

        # Two chunks of one messageId for a split reply, one otherwise.
        def say(turn, text, split: false)
          message_id = "#{turn.session}:#{turn.request_id}"
          pieces = split ? [text[0, text.length / 2], text[(text.length / 2)..]] : [text]
          pieces.each do |piece|
            update(turn.session, { "sessionUpdate" => "agent_message_chunk", "messageId" => message_id,
                                   "content" => { "type" => "text", "text" => piece } })
          end
        end

        # `sleep N` ticks; any other prompt is echoed as in plain mode.
        def sleep_turn(turn, text)
          asked = text[/\Asleep\s+(\d+)\z/, 1]
          return plain_turn(turn, text) unless asked

          (([asked.to_i, MAX_SLEEP_SECONDS].min) / TICK_SECONDS).to_i.times do |n|
            return nil if turn.cancelled

            say(turn, n.zero? ? "tick" : " tick")
            sleep TICK_SECONDS
          end
          nil
        end

        def die_turn(turn)
          say(turn, "about to go")
          log "dying with status 3"
          exit! 3
        end

        def permission_turn(turn, text)
          asks = text.lines.map(&:strip).filter_map { |line| ask_for(line) }
          asks = [ask_for("run npm test")] if asks.empty?
          words = []
          asks.each_with_index do |ask, n|
            break if turn.cancelled

            words << permission_word(turn, ask, n)
          end
          words.join("\n")
        end

        def ask_for(line)
          if (command = line[/\Arun\s+(.+)\z/, 1])
            { "kind" => "execute", "title" => "run #{command}", "rawInput" => { "command" => command } }
          elsif (path = line[/\Aedit\s+(\S+)\z/, 1])
            { "kind" => "edit", "title" => "edit #{path}", "rawInput" => { "path" => path }, "locations" => [{ "path" => path }] }
          else nil
          end
        end

        def permission_word(turn, ask, n)
          tool_call_id = "#{turn.session}:call-#{turn.request_id}-#{n}"
          update(turn.session, { "sessionUpdate" => "tool_call", "toolCallId" => tool_call_id, "status" => "pending" }.merge(ask))
          tool_call = @mode == "id_only" ? { "toolCallId" => tool_call_id } : { "toolCallId" => tool_call_id }.merge(ask)
          outcome = ask_peer(turn, "session/request_permission", {
            "sessionId" => turn.session, "toolCall" => tool_call,
            "options" => [
              { "optionId" => "allow", "name" => "Allow", "kind" => "allow_once" },
              { "optionId" => "always", "name" => "Always", "kind" => "allow_always" },
              { "optionId" => "reject", "name" => "Reject", "kind" => "reject_once" },
            ],
          })
          settle_tool_call(turn, tool_call_id, outcome)
        end

        def settle_tool_call(turn, tool_call_id, outcome)
          decision = outcome.is_a?(Hash) ? outcome.fetch("outcome", {}) : {}
          await_session_cancel(turn) if decision["outcome"] == "cancelled"
          if decision["outcome"] == "selected" && %w[allow always].include?(decision["optionId"])
            update(turn.session, { "sessionUpdate" => "tool_call_update", "toolCallId" => tool_call_id, "status" => "in_progress" })
            update(turn.session, { "sessionUpdate" => "tool_call_update", "toolCallId" => tool_call_id, "status" => "completed" })
            "allowed:#{decision["optionId"]}"
          else
            update(turn.session, { "sessionUpdate" => "tool_call_update", "toolCallId" => tool_call_id, "status" => "failed" })
            decision["outcome"] == "selected" ? "rejected:#{decision["optionId"]}" : "cancelled"
          end
        end

        # The spec's word: a `cancelled` outcome comes with a `session/cancel`; bounded.
        def await_session_cancel(turn)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CANCELLED_OUTCOME_WAIT_SECONDS
          sleep POLL_SECONDS while turn.cancelled.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        end

        def elicit_turn(turn)
          answer = ask_peer(turn, "elicitation/create", {
            "sessionId" => turn.session, "mode" => "form", "message" => "Which colour?",
            "requestedSchema" => { "type" => "object", "properties" => { "answer" => { "type" => "string" } }, "required" => ["answer"] },
          })
          return "cancelled" unless answer.is_a?(Hash)

          answer["action"] == "accept" ? "answer:#{answer.dig("content", "answer")}" : "elicitation:#{answer["action"]}"
        end

        # --- outbound requests --------------------------------------------

        # A request to the client, awaited on the turn's thread: the
        # client's result, or nil when it errored (-32800 after our own
        # cascade included), never answered within the bound, or the turn
        # was aborted meanwhile.
        def ask_peer(turn, method, params)
          queue = Queue.new
          id = @lock.synchronize do
            id = @next_id
            @next_id += 1
            @pending[id] = [queue, turn]
            turn.outstanding << id
            id
          end
          write({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
          answer = queue.pop(timeout: MAX_SLEEP_SECONDS)
          answer.is_a?(Hash) && answer.key?("result") ? answer["result"] : nil
        end

        # The main thread's: the pending and the turn's outstanding entry
        # go together, in wire order.
        def response(id, message)
          queue = @lock.synchronize do
            queue, turn = @pending.delete(id)
            turn&.outstanding&.delete(id)
            queue
          end
          queue&.push(message)
        end

        def drop_outstanding(turn, ids)
          @lock.synchronize do
            ids.each do |id|
              queue, = @pending.delete(id)
              turn.outstanding.delete(id)
              queue&.push(nil)
            end
          end
        end

        # --- notifications ------------------------------------------------

        def notification(method, params)
          case method
          when "session/cancel" then cancel_session(params.is_a?(Hash) ? params["sessionId"] : nil)
          when "$/cancel_request" then cancel_request(params.is_a?(Hash) ? params["requestId"] : nil)
          else nil
          end
        end

        def cancel_session(session)
          return if @mode == "ignore_cancel"

          turn = @lock.synchronize { @turns[session] }
          return unless turn

          turn.cancelled ||= :cancelled
          cascade(turn)
        end

        # THE CASCADE (the cancellation page): our own outstanding requests
        # get `$/cancel_request`; the client's answer (-32800 or a result)
        # is consumed by `response`; a client that never answers is waited
        # out, bounded, then the waits are released.
        def cascade(turn)
          ids = @lock.synchronize { turn.outstanding.dup }
          return if ids.empty?

          ids.each { |id| notify("$/cancel_request", { "requestId" => id }) }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CASCADE_WAIT_SECONDS
          Thread.new do
            until @lock.synchronize { (turn.outstanding & ids).empty? } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              sleep POLL_SECONDS
            end
            drop_outstanding(turn, ids)
          end
        end

        def cancel_request(id)
          return if @mode == "ignore_cancel"

          turn = @lock.synchronize { @turns.values.find { |candidate| candidate.request_id == id } }
          return unless turn

          turn.cancelled = :aborted
          drop_outstanding(turn, @lock.synchronize { turn.outstanding.dup })
        end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { mode: "plain", protocol_version: 1 }
  OptionParser.new do |parser|
    parser.on("--mode MODE") { |mode| options[:mode] = mode }
    parser.on("--protocol-version N", Integer) { |n| options[:protocol_version] = n }
  end.parse!(ARGV)
  exit E2E::AcpFixture::Agent.new(**options).run
end
