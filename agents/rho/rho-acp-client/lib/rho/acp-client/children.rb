require "securerandom"
require "rho"
require "rho/runner"
require "rho/acp"
require_relative "capture"

module Rho
  module AcpClient
    # THE CHILDREN TABLE:
    # ONE RESIDENT CHILD PER (conversation, agent), in its own process
    # group (`OwnedProcess`, the `true(1)` guard reserving the pgid), its
    # environment REPLACED by the scrubbed one plus the row's own, its
    # sessions multiplexed on it; `initialize` once, `session/new` per
    # session, a call per `session/prompt`. Module state under a LOCK
    # (rho-mcp's pattern) — the child map keyed by the pair, the session
    # map keyed by rho's OWN session id (`acp-<hex>`: the child's id is
    # its own and two children may mint the same one), and the exits of
    # sessions that are gone, kept so a call against a dead child answers
    # by name and is never revived under the same id (the truthful-
    # registry rule). LIFETIME FOLLOWS THE CONVERSATION: `release` on the
    # daemon's `:host_ended`, `close!` on `:shutdown`, `sweep!` retiring a
    # child whose watcher recorded an exit between calls, `kill` the
    # person's verb.
    #
    # A child is NOT in the person's process table: extension-held state
    # like an MCP connection, whose pump would eat the wire. Its group is
    # owned here and killed on every exit path.
    module Children
      LOCK = Mutex.new
      EXITS_KEPT = 256
      POLL_SECONDS = 0.02
      AWAIT_SLICE_SECONDS = 0.1
      # The ladder's stages (stdin closed, TERM, KILL), each bounded; a
      # session's close asked before it, bounded too.
      CLOSE_STAGE_SECONDS = 3.0
      SESSION_CLOSE_SECONDS = 2.0
      # A death is settled — the watcher's record, the stderr drain's EOF
      # — within this before the sentence quotes the tail.
      SETTLE_SECONDS = 1.0
      STDERR_KEEP_BYTES = 4096
      # The child's `cancelled` answer after the worker returned: awaited
      # on a thread of the table's, logged, bounded.
      CANCEL_ANSWER_SECONDS = 5.0
      CLOSE_JOIN_SECONDS = 12.0
      Methods = Rho::Acp::Methods

      Session = Struct.new(:id, :child, :acp_id, :cwd, :opened_at, :last_prompt_at, :calls, :tool_calls, keyword_init: true) do
        def document
          { "session" => id, "agent" => child.row.key, "conversation" => child.conversation, "cwd" => cwd,
            "pid" => child.pid, "pgid" => child.group_pid, "acp_session" => acp_id,
            "opened_at" => opened_at&.utc&.iso8601, "last_prompt_at" => last_prompt_at&.utc&.iso8601, "calls" => calls,
            "capture" => child.capture&.path }
        end
      end

      # ONE CHILD: the process in its group, the connection over its
      # separate pipe ends (never a popen handle: `Wire#close` closes the
      # IO it was given, and `IO#close` on a popen handle waits for the
      # child), a 4 KiB stderr tail, a watcher recording the exit, and the
      # capture every line both ways is appended to. Its mutex serializes
      # the handshake and the turns on it; `hold` takes it cancellably.
      class Child
        attr_reader :row, :conversation, :capture, :redact, :sessions, :agent_info, :capabilities, :auth_methods,
          :spawned_at, :exit_status, :exited_at, :cwd

        def initialize(row, conversation:, redact:, log:, clock:, capture: nil)
          @row = row
          @conversation = conversation
          @redact = redact
          @log = log
          @clock = clock
          @capture = capture
          @sessions = []
          @mutex = Mutex.new
          @process = nil
          @connection = nil
          @tail = String.new(encoding: Encoding::BINARY)
          @tail_lock = Mutex.new
          @exit_status = nil
          @exited_at = nil
          @authenticated = false
          @spawned_at = nil
          @cwd = nil
          @cancelled_prompt = nil
        end

        def spawned? = !@process.nil?

        def pid = @process&.pid

        def group_pid = @process&.group_pid

        def exited? = !@exit_status.nil?

        def closed? = @connection.nil? || @connection.closed?

        # "status 3" / "signal 9" / "status unknown": the exit as a sentence names it.
        def exit_description
          status = @exit_status
          return "status unknown" if status.nil? || status == :unknown

          status.signaled? ? "signal #{status.termsig}" : "status #{status.exitstatus}"
        end

        def stderr_tail
          @tail_lock.synchronize { @tail.dup.force_encoding(Encoding::UTF_8).scrub }
        end

        # The mutex, taken without blocking a cancellation: a worker
        # waiting for the child meets a stop or the deadline here.
        def hold(env)
          until @mutex.try_lock
            env&.raise_if_cancelled!
            sleep POLL_SECONDS
          end
          begin
            finish_cancelled_prompt
            yield
          ensure
            @mutex.unlock
          end
        end

        # THE SPAWN: its own group, the pipes' child ends
        # handed over and closed here, `unsetenv_others: true` so `env`
        # REPLACES the environment, `chdir:` the session's cwd.
        def spawn!(env:, cwd:)
          stdin_r, stdin_w = IO.pipe
          stdout_r, stdout_w = IO.pipe
          stderr_r, stderr_w = IO.pipe
          begin
            @process = Rho::Runner::OwnedProcess.spawn(
              env, @row.command, *@row.args,
              chdir: cwd, in: stdin_r, out: stdout_w, err: stderr_w, unsetenv_others: true
            )
          rescue SystemCallError, ArgumentError => error
            [stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w].each(&:close)
            raise Unavailable, "acp agent \"#{@row.key}\": failed to start: #{@redact.call(error.message)}"
          ensure
            [stdin_r, stdout_w, stderr_w].each { |io| io.close unless io.closed? }
          end
          @cwd = cwd
          @spawned_at = @clock.call
          stdout_r.binmode
          @connection = Rho::Acp::Connection.new(Rho::Acp::Wire.new(input: stdout_r, output: stdin_w))
          @stderr_thread = Thread.new { drain_stderr(stderr_r) }
          @stderr_thread.name = "rho-acp-stderr-#{@process.pid}"
          @watcher = Thread.new { watch_exit(@process) }
          @watcher.name = "rho-acp-watcher-#{@process.pid}"
          @capture&.line(:note, nil, event: "spawned", agent: @row.key, conversation: @conversation, pid: pid, pgid: group_pid,
            launch: @row.launch, cwd: cwd)
          @log&.info("acp.child_spawned", agent: @row.key, conversation: @conversation, pid: pid, pgid: group_pid)
          self
        end

        # THE HANDSHAKE: `initialize` with the baseline client capabilities
        # (rho serves neither `fs/*` nor `terminal/*`); a
        # `protocolVersion` other than 1 is `acp_version`, the child closed.
        def handshake!(deadline:, env: nil)
          result = await(request(Methods::INITIALIZE, {
            "protocolVersion" => Methods::PROTOCOL_VERSION,
            "clientCapabilities" => Methods::BASELINE_CLIENT_CAPABILITIES,
            "clientInfo" => { "name" => "rho", "version" => Rho::VERSION },
          }), deadline: deadline, env: env, what: Methods::INITIALIZE)
          result = Hash.try_convert(result) || {}
          version = result["protocolVersion"]
          unless version == Methods::PROTOCOL_VERSION
            raise Refused, "acp_version: acp agent \"#{@row.key}\" speaks protocol version #{version.inspect.delete('"')}; " \
                           "this client speaks #{Methods::PROTOCOL_VERSION}"
          end

          @agent_info = Hash.try_convert(result["agentInfo"]) || {}
          @capabilities = Hash.try_convert(result["agentCapabilities"]) || {}
          @auth_methods = Array(result["authMethods"]).filter_map { |method| Hash.try_convert(method) }
          self
        end

        # A SESSION: `session/new {cwd, mcpServers: []}` (rho hands NO
        # servers: a third party would receive rho's secrets); on -32000
        # `authenticate` once with the row's method or the sole agent-type
        # one, then again; still refused, or only terminal-type methods →
        # `acp_auth_required` naming the ids and the probe verb. The row's
        # `model` is set when the child listed a `category: "model"` option.
        def open_session(cwd:, deadline:, env: nil)
          result = new_session(cwd, deadline, env)
          acp_id = String.try_convert(result["sessionId"])
          raise Refused, "acp agent \"#{@row.key}\" answered session/new without a sessionId" if acp_id.nil? || acp_id.empty?

          set_model(acp_id, result["configOptions"], deadline, env)
          acp_id
        end

        def request(method, params = nil)
          pending = @connection.request(method, params)
          @capture&.line(:out, { "id" => pending.id, "method" => method, "params" => params })
          pending
        rescue Rho::Acp::Closed
          raise Unavailable, gone_sentence("before #{method} could be sent")
        end

        def notify(method, params = nil)
          @capture&.line(:out, { "method" => method, "params" => params })
          @connection.notify(method, params)
        end

        # Waits cancellably, in slices, under the deadline; the answer or
        # the peer's error is captured as it lands.
        def await(pending, deadline:, env: nil, what: nil)
          loop do
            env&.raise_if_cancelled!
            begin
              result = pending.wait(timeout: AWAIT_SLICE_SECONDS)
              @capture&.line(:in, { "id" => pending.id, "result" => result })
              return result
            rescue Rho::Acp::Unanswered
              next unless Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

              raise Refused, "acp agent \"#{@row.key}\" did not answer #{what || "request #{pending.id}"} in time"
            rescue Rho::Acp::RemoteError => error
              @capture&.line(:in, { "id" => pending.id, "error" => { "code" => error.code, "message" => error.message, "data" => error.data } })
              raise
            rescue Rho::Acp::Closed
              settle(SETTLE_SECONDS)
              raise Unavailable, gone_sentence("during #{what || "request #{pending.id}"}")
            end
          end
        end

        # Observes a request's late answer on a thread of the table's —
        # the child's `cancelled` after the worker returned — bounded.
        # Called while holding the child: retain this same Pending until
        # its final updates have been consumed before the next request.
        def observe_late(pending, session_id)
          @cancelled_prompt = pending
          Thread.new do
            result = pending.wait(timeout: CANCEL_ANSWER_SECONDS)
            @capture&.line(:in, { "id" => pending.id, "result" => result })
            @log&.info("acp.cancel_answered", agent: @row.key, session: session_id,
              stop: Hash.try_convert(result)&.dig("stopReason"))
          rescue Rho::Acp::RemoteError => error
            @capture&.line(:in, { "id" => pending.id, "error" => { "code" => error.code, "message" => error.message } })
          rescue Rho::Acp::Unanswered, Rho::Acp::Closed => error
            @log&.warn("acp.cancel_unanswered", agent: @row.key, session: session_id, error_class: error.class.name)
          end
        end

        # The next inbound event, captured on receipt; nil at the timeout
        # or once closed.
        def receive(timeout:)
          event = @connection.receive(timeout: timeout)
          case event
          in Rho::Acp::Connection::Inbound
            @capture&.line(:in, { "id" => event.id, "method" => event.method, "params" => event.params })
          in Rho::Acp::Wire::Notification
            @capture&.line(:in, { "method" => event.method, "params" => event.params })
          else nil
          end
          event
        end

        def answer(inbound, result)
          @capture&.line(:out, { "id" => inbound.id, "result" => result })
          inbound.respond(result)
        rescue Rho::Acp::Closed, Rho::Acp::Error
          nil
        end

        def refuse(inbound, code, message)
          @capture&.line(:out, { "id" => inbound.id, "error" => { "code" => code, "message" => message } })
          inbound.fail(code, message)
        rescue Rho::Acp::Closed, Rho::Acp::Error
          nil
        end

        # After a death: the watcher's record and the drain's EOF, bounded.
        def settle(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          sleep POLL_SECONDS while !exited? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @stderr_thread&.join([remaining, 0.05].max) if exited?
          exited?
        end

        # THE LADDER: `session/close` per live session, the
        # connection closed (stdin's EOF), wait; TERM the group, wait; KILL
        # and reap. Idempotent.
        def stop!(session_ids: [])
          return release if @process.nil?

          close_sessions(session_ids) unless closed? || exited?
          begin
            @connection&.close
          rescue StandardError
            nil
          end
          @process.terminate("TERM") unless exited_within(CLOSE_STAGE_SECONDS)
          exited_within(CLOSE_STAGE_SECONDS)
        ensure
          release
        end

        # THE POISON RULE'S TEARDOWN: KILL the group and reap it, no stage.
        def kill!
          return release if @process.nil?

          begin
            @process.kill_and_reap
          rescue StandardError
            nil
          end
        ensure
          release
        end

        private

          # Updates identify a session, not a prompt. Once the old response
          # has arrived, all updates preceding it are queued by Connection;
          # consume them under the same mutex before a new call can send.
          # A child still cancelling stays alive but admits no new work.
          def finish_cancelled_prompt
            return if @cancelled_prompt.nil?

            unless @cancelled_prompt.done?
              raise Refused, "acp agent \"#{@row.key}\" is still finishing its cancelled delegation; retry once it finishes"
            end

            while (event = receive(timeout: 0))
              case event
              in Rho::Acp::Connection::Inbound
                refuse(event, Methods::ErrorCode::REQUEST_CANCELLED,
                  Methods::ErrorCode::MESSAGES.fetch(Methods::ErrorCode::REQUEST_CANCELLED))
              else
                nil
              end
            end
            @cancelled_prompt = nil
          end

          def new_session(cwd, deadline, env, authenticated: false)
            await(request(Methods::SESSION_NEW, { "cwd" => cwd, "mcpServers" => [] }), deadline: deadline, env: env,
              what: Methods::SESSION_NEW)
          rescue Rho::Acp::RemoteError => error
            raise Refused, "acp agent \"#{@row.key}\" refused session/new (#{error.code}): #{@redact.call(error.message)}" unless
              error.code == Methods::ErrorCode::AUTH_REQUIRED
            raise Refused, auth_required_sentence if authenticated || @authenticated

            authenticate!(deadline, env)
            new_session(cwd, deadline, env, authenticated: true)
          end

          def authenticate!(deadline, env)
            method = @row.auth_method || sole_agent_method || raise(Refused, auth_required_sentence)
            await(request(Methods::AUTHENTICATE, { "methodId" => method }), deadline: deadline, env: env,
              what: Methods::AUTHENTICATE)
            @authenticated = true
          rescue Rho::Acp::RemoteError => error
            raise Refused, "#{auth_required_sentence} (authenticate #{method.inspect} was refused: #{@redact.call(error.message)})"
          end

          # The one agent-type method, when there is exactly one.
          def sole_agent_method
            agents = Array(@auth_methods).reject { |method| method["type"] == Methods::AuthMethodType::TERMINAL }
            agents.length == 1 ? agents.fetch(0)["id"] : nil
          end

          def auth_required_sentence
            methods = Array(@auth_methods).map { |method| "#{method["id"]} (#{method["type"] || Methods::AuthMethodType::AGENT})" }
            listed = methods.empty? ? "none listed" : methods.join(", ")
            "acp_auth_required: acp agent \"#{@row.key}\" needs a login this runner cannot perform (its methods: #{listed}); " \
              "run its own program's login by hand, then `rho acp-agents probe #{@row.key}`"
          end

          def set_model(acp_id, options, deadline, env)
            return if @row.model.nil?

            option = Array(options).filter_map { |candidate| Hash.try_convert(candidate) }
              .find { |candidate| candidate["category"] == "model" }
            return if option.nil?

            await(request(Methods::SESSION_SET_CONFIG_OPTION,
              { "sessionId" => acp_id, "configId" => option["id"], "value" => @row.model }),
              deadline: deadline, env: env, what: Methods::SESSION_SET_CONFIG_OPTION)
          rescue Rho::Acp::RemoteError => error
            raise Refused, "acp agent \"#{@row.key}\" refused model #{@row.model.inspect}: #{@redact.call(error.message)}"
          end

          def close_sessions(session_ids)
            session_ids.each do |acp_id|
              pending = request(Methods::SESSION_CLOSE, { "sessionId" => acp_id })
              await(pending, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + SESSION_CLOSE_SECONDS,
                what: Methods::SESSION_CLOSE)
            rescue Rho::Acp::Error, Error
              nil
            end
          end

          def gone_sentence(when_text)
            settle(SETTLE_SECONDS)
            "acp agent \"#{@row.key}\" #{exited? ? "exited (#{exit_description})" : "stopped answering"} #{when_text}" \
              "#{tail_clause}"
          end

          def tail_clause
            tail = @redact.call(stderr_tail).strip
            tail.empty? ? "" : "; its stderr ended: #{tail.lines.last.to_s.strip}"
          end

          def drain_stderr(io)
            while (chunk = io.readpartial(STDERR_KEEP_BYTES))
              @tail_lock.synchronize do
                @tail << chunk
                overflow = @tail.bytesize - STDERR_KEEP_BYTES
                @tail = @tail.byteslice(overflow..) if overflow.positive?
              end
            end
          rescue EOFError, IOError
            nil
          end

          def watch_exit(process)
            status = process.wait(check_cancellation: false)
            @exited_at = @clock.call
            @exit_status = status || :unknown
          rescue StandardError
            @exited_at = @clock.call
            @exit_status = :unknown
          end

          def exited_within(seconds)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
            sleep POLL_SECONDS until exited? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            exited?
          end

          # The last word of both teardowns: the guard reaped, the threads
          # joined briefly, the connection closed.
          def release
            begin
              @process&.kill_and_reap
            rescue StandardError
              nil
            end
            @watcher&.join(0.5)
            begin
              @connection&.close
            rescue StandardError
              nil
            end
            @stderr_thread&.join(0.5)
            nil
          end
      end

      class << self
        def closed? = LOCK.synchronize { @closed == true }

        # THE CHILD AND THE SESSION A CALL RUNS ON. `session` names a
        # session to continue (its child must be this agent's and alive;
        # a `workdir` given that differs from its cwd is refused by name);
        # else a NEW session on the pair's child, spawned and handshaken
        # when there is none.
        def acquire(row, conversation:, cwd:, workdir_given:, session:, env:, artifacts_dir:, log:, clock:, current_env: ENV.to_h)
          return continued(row, session, cwd, workdir_given, log) if session

          id = "acp-#{SecureRandom.hex(6)}"
          child = child_for(row, conversation, id, artifacts_dir, log, clock)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (row.timeout_ms / 1000.0)
          child.hold(env) do
            begin
              unless child.spawned?
                child.spawn!(env: Rho::AcpClient.child_env(row, current_env), cwd: cwd)
                LOCK.synchronize { ensure_current_child(child) }
                child.handshake!(deadline: deadline, env: env)
              end
              acp_id = child.open_session(cwd: cwd, deadline: deadline, env: env)
              opened = Session.new(id: id, child: child, acp_id: acp_id, cwd: cwd, opened_at: clock.call,
                last_prompt_at: nil, calls: 0, tool_calls: {})
              LOCK.synchronize do
                ensure_current_child(child)
                (@sessions ||= {})[id] = opened
                child.sessions << acp_id
              end
              log&.info("acp.session_opened", agent: row.key, conversation: conversation, session: id, acp_session: acp_id,
                cwd: cwd)
              opened
            rescue Unavailable, Refused, Rho::Runner::ExecutionContext::Cancelled
              discard(child, log)
              raise
            end
          end
        end

        # The rows of `GET /acp` and `rho acp-agents sessions`.
        def sessions
          LOCK.synchronize { (@sessions || {}).values.map(&:document) }
        end

        def session_document(id) = LOCK.synchronize { (@sessions || {})[id]&.document }

        def children_of(agent_key)
          LOCK.synchronize { (@children || {}).values.count { |child| child.row.key == agent_key } }
        end

        # A CHILD DIES: its rows gone, its sessions remembered by their
        # exit, the capture closed, the group reaped.
        def retire(child, reason:, log:, kill: false)
          taken = LOCK.synchronize { take_locked(child, reason) }
          return if taken.nil?

          kill ? child.kill! : child.stop!
          child.capture&.note("retired", agent: child.row.key, reason: reason)
          child.capture&.close
          if kill
            log&.warn("acp.child_killed", agent: child.row.key, conversation: child.conversation, pid: child.pid,
              pgid: child.group_pid, reason: reason)
          else
            log&.warn("acp.child_exited", agent: child.row.key, conversation: child.conversation, pid: child.pid,
              exit: child.exit_description, reason: reason)
          end
          nil
        end

        # `:host_ended`: every child of the conversation, closed on a
        # thread of the table's — sessions closed, then the ladder.
        def release(conversation, log:)
          taken = LOCK.synchronize do
            (@children || {}).values.select { |child| child.conversation == conversation }
              .map { |child| [child, take_locked(child, "released when its conversation ended")] }
          end
          log&.info("acp.host_ended", conversation: conversation, children: taken.length)
          return if taken.empty?

          Thread.new do
            taken.each do |child, acp_ids|
              child.stop!(session_ids: acp_ids)
              child.capture&.note("released", agent: child.row.key, conversation: conversation)
              child.capture&.close
            rescue StandardError
              nil
            end
          end
          nil
        end

        # `:shutdown`: every child, in parallel, bounded.
        def close!(log: nil)
          taken = LOCK.synchronize do
            @closed = true
            (@children || {}).values.map { |child| [child, take_locked(child, "closed at shutdown")] }
          end
          close_all(taken)
          log&.info("acp.closed", children: taken.length)
          nil
        end

        # For tests: forget everything — the exits too — in one section.
        def reset!
          taken = LOCK.synchronize do
            current = (@children || {}).values.map { |child| [child, child.sessions.dup] }
            @children = {}
            @sessions = {}
            @exits = {}
            @closed = false
            current
          end
          close_all(taken)
          nil
        end

        # THE SWEEP: a child whose watcher recorded an exit between calls
        # is retired now, not at the next call. Answers how many.
        def sweep!(log: nil)
          dead = LOCK.synchronize { (@children || {}).values.select(&:exited?) }
          dead.each { |child| retire(child, reason: "exited between calls", log: log) }
          dead.length
        end

        # `rho acp-agents kill SESSION`: the session's whole child, KILLed.
        def kill(session_id, log: nil)
          child = LOCK.synchronize { (@sessions || {})[session_id]&.child }
          return false if child.nil?

          retire(child, reason: "killed by rho acp-agents kill", log: log, kill: true)
          true
        end

        private

          # A release can take an admitted child before it spawns or while
          # its handshake is in flight. Only the table's current object may
          # continue opening or publish a session; cleanup stays outside LOCK.
          def ensure_current_child(child)
            return if (@children || {})[[child.conversation, child.row.key]].equal?(child)

            raise Refused, "acp agent \"#{child.row.key}\" was released before its session opened"
          end

          def continued(row, session_id, cwd, workdir_given, log)
            found, gone = LOCK.synchronize { [(@sessions || {})[session_id], (@exits || {})[session_id]] }
            if found.nil?
              raise Refused, "session #{session_id}'s #{gone}; the session is gone — omit `session` to open one" if gone

              raise Refused, "no session #{session_id} on this runner; omit `session` to open one"
            end
            if found.child.row.key != row.key
              raise Refused, "session #{session_id} belongs to agent \"#{found.child.row.key}\", not \"#{row.key}\""
            end
            if found.child.exited?
              retire(found.child, reason: "exited between calls", log: log)
              return continued(row, session_id, cwd, workdir_given, log)
            end
            if workdir_given && found.cwd != cwd
              raise Refused, "session #{session_id} works in #{found.cwd}; a session's workdir is fixed at its birth — " \
                             "omit `session` to open one in #{cwd}"
            end

            found
          end

          # The pair's child, or a fresh one placed under the lock (its
          # spawn happens under the child's own mutex, never the table's).
          def child_for(row, conversation, session_id, artifacts_dir, log, clock)
            LOCK.synchronize do
              raise Closed, "the acp client is shutting down" if @closed

              @children ||= {}
              key = [conversation, row.key]
              existing = @children[key]
              if existing&.exited?
                take_locked(existing, "exited between calls")
                existing = nil
              end
              return existing if existing

              redact = Rho::Runner::Redact.new(row.secrets)
              capture = artifacts_dir && Capture.new(Capture.path_for(artifacts_dir, row.key, session_id), redact: redact, clock: clock)
              @children[key] = Child.new(row, conversation: conversation, redact: redact, log: log, clock: clock, capture: capture)
            end
          end

          # A child that could not be spawned, handshaken or given a
          # session is not kept: nothing to revive, nothing to list.
          def discard(child, log)
            sessions = LOCK.synchronize { take_locked(child, "closed after a failed start") }
            # Already taken does not mean process creation finished before
            # the taker's teardown. Reap this exact child, never its replacement.
            sessions.nil? ? child.kill! : child.stop!(session_ids: sessions)
            child.capture&.close
            log&.warn("acp.child_discarded", agent: child.row.key, conversation: child.conversation, pid: child.pid)
          end

          # Under the LOCK: the child and its sessions out of the maps, the
          # sessions' exits remembered. Answers the child's ACP session ids,
          # nil when it was already taken.
          def take_locked(child, reason)
            @children ||= {}
            @sessions ||= {}
            @exits ||= {}
            key = [child.conversation, child.row.key]
            return nil unless @children[key].equal?(child)

            @children.delete(key)
            phrase = child.exited? ? "agent \"#{child.row.key}\" exited (#{child.exit_description})" : "agent \"#{child.row.key}\" was #{reason}"
            @sessions.delete_if do |id, session|
              next false unless session.child.equal?(child)

              @exits[id] = phrase
              true
            end
            @exits.shift while @exits.length > EXITS_KEPT
            child.sessions.dup
          end

          def close_all(taken)
            threads = taken.map do |child, acp_ids|
              Thread.new do
                child.stop!(session_ids: acp_ids)
                child.capture&.close
              rescue StandardError
                nil
              end
            end
            threads.each { |thread| thread.join(CLOSE_JOIN_SECONDS) }
            nil
          end
      end
    end
  end
end
