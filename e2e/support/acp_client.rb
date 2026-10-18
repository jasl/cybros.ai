require "json"
require_relative "process_runner"

# THE NAMES COME FROM THE GEM (the protocol lives in the `rho-acp` gem): the method strings, the
# version, the vocabularies — by load path, the way the kernel-tool-names pin reads rho's registry;
# `methods.rb` is data with no requires, so no bundle is needed. The framing below is the harness's
# OWN: the wire is re-implemented here so this client checks the gem's `Wire`/`Connection` from the
# outside when it drives `rho-acp`.
ACP_CLIENT_RHO_ACP_LIB = File.expand_path("../../agents/rho/rho-acp/lib", __dir__)
$LOAD_PATH.unshift(ACP_CLIENT_RHO_ACP_LIB) unless $LOAD_PATH.include?(ACP_CLIENT_RHO_ACP_LIB)
require "rho/acp/methods"

module E2E
  # THE SCRIPTED ACP CLIENT: spawns an agent command over `IO.popen("r+")` in its OWN process group
  # with stderr to a file (the failure dump prints it), then plays the client by the spec —
  # `initialize`, `session/new`, `session/prompt` with the turn's `session/update`s collected, the
  # agent's `session/request_permission` and `elicitation/create` answered by a SCRIPTED POLICY (or
  # held open for a test that wants to watch the agent's cancel cascade), `session/cancel`
  # (answering held permission requests `cancelled` first, the spec's rule for the client),
  # `$/cancel_request` on its own outstanding request, and a bounded close that ends the whole
  # group. Raw lines can be written and counted for the registry's one-line shape. A READER THREAD
  # parses stdout into the tables and answers policy questions there — a policy is a pure function;
  # `:hold` keeps the request for the test's thread.
  #
  # THE EDITOR'S BUFFERS: a client that advertised `clientCapabilities.fs` serves
  # `fs/read_text_file` and `fs/write_text_file` from a scripted BUFFER TABLE — absolute path →
  # text, the unsaved buffers an editor holds — so the lane proves rho's `read` sees a buffer whose
  # disk copy differs and a `write` lands in the buffer, never on disk. A read answers `{content}`
  # windowed by the spec's 1-based `line` and `limit`; a path the table lacks is the client's -32002
  # (the surface's `not_found`); a write replaces the buffer whole and answers `{}`. A flag the
  # client did NOT advertise is never served: the method is -32601, as every terminal method is —
  # the surface must never call what it was not told. The table is replaced, never mutated, under
  # the lock.
  class AcpClient
    Methods = Rho::Acp::Methods
    CLIENT_INFO = { "name" => "e2e-acp-client", "title" => "E2E ACP client", "version" => "1" }.freeze
    DEFAULT_POLICY = { permission: :allow, elicitation: :decline, cancel_answers_held: true }.freeze
    DEFAULT_TIMEOUT = 10
    EXIT_WAIT_SECONDS = 3
    POLL_SECONDS = 0.02
    FS_FLAGS = { Methods::FS_READ_TEXT_FILE => "readTextFile", Methods::FS_WRITE_TEXT_FILE => "writeTextFile" }.freeze

    # A `clientCapabilities` document in the schema's shape: the fs flags, no terminal, the terminal
    # auth flag, and the two elicitation modes as `{}` when offered (the schema's "supported").
    def self.capabilities(read: false, write: false, form: false, url: false, terminal_auth: false)
      {
        "fs" => { "readTextFile" => read, "writeTextFile" => write },
        "terminal" => false,
        "auth" => { "terminal" => terminal_auth },
        "elicitation" => { "form" => form ? {} : nil, "url" => url ? {} : nil }.compact,
      }
    end

    class Error < StandardError; end
    class Closed < Error; end
    class Unanswered < Error; end

    class RemoteError < Error
      attr_reader :code, :data

      def initialize(error)
        super(error["message"].to_s)
        @code = error["code"]
        @data = error["data"]
      end
    end

    # One prompt turn as the client saw it: the stop reason, the session's
    # updates (each carrying its `sessionId`), the agent's text (every
    # `agent_message_chunk` joined), the permission and elicitation
    # requests the agent made meanwhile, with what we answered.
    Turn = Data.define(:stop_reason, :updates, :text, :permissions, :elicitations)

    attr_reader :pid, :stdout_lines, :updates, :requests_seen, :stray_failures, :cancel_notices, :exit_status,
      :protocol_version, :client_capabilities, :agent_capabilities, :agent_info, :auth_methods

    # `buffers` is the editor's table: absolute path → the buffer's text.
    def self.spawn(command, env: {}, chdir: nil, stderr: nil, policy: {}, buffers: {})
      new(command, env: env, chdir: chdir, stderr: stderr, policy: policy, buffers: buffers)
    end

    def initialize(command, env:, chdir:, stderr:, policy:, buffers: {})
      options = { pgroup: true, err: stderr ? [stderr, "a"] : $stderr }
      options[:chdir] = chdir if chdir
      @io = IO.popen(env, command, "r+", **options)
      @io.set_encoding(Encoding::UTF_8)
      @pid = @io.pid
      @stderr_path = stderr
      @policy = DEFAULT_POLICY.merge(policy)
      @buffers = buffers.to_h { |path, text| [path.to_s, text.to_s] }.freeze
      @lock = Mutex.new
      @write_lock = Mutex.new
      @pending = {}
      @unclaimed = {}
      @next_id = 0
      @stdout_lines = []
      @updates = []
      @requests_seen = []
      @held = {}
      @held_queue = Queue.new
      @stray_failures = []
      @cancel_notices = []
      @turn_marks = {}
      @closed = false
      @exit_status = nil
      @auth_methods = []
      @reader = Thread.new { read_loop }
      @reader.name = "e2e-acp-client-reader-#{@pid}"
    end

    # --- raw ------------------------------------------------------------

    def write_raw(line)
      @write_lock.synchronize do
        @io.write("#{line}\n")
        @io.flush
      end
      nil
    rescue IOError, Errno::EPIPE
      raise Closed, "the agent's stdin is closed"
    end

    # No new stdout line within `seconds`.
    def quiet?(seconds)
      before = @lock.synchronize { @stdout_lines.length }
      sleep seconds
      @lock.synchronize { @stdout_lines.length } == before
    end

    # --- JSON-RPC -------------------------------------------------------

    def send_request(method, params = nil)
      id = @lock.synchronize do
        id = @next_id
        @next_id += 1
        @pending[id] = Queue.new
        id
      end
      write_raw(JSON.generate(frame(id, method, params)))
      id
    end

    # The result for `id`, or `RemoteError`, `Closed`, `Unanswered`. Works
    # for an id written raw too: an answer nobody waited for is kept.
    def await(id, timeout: DEFAULT_TIMEOUT)
      queue = @lock.synchronize do
        message = @unclaimed.delete(id)
        break message if message

        @pending[id] ||= Queue.new
      end
      message = queue.is_a?(Queue) ? queue.pop(timeout: timeout) : queue
      raise Unanswered, "no answer to request #{id} within #{timeout}s" if message.nil?
      raise Closed, "the agent went away before answering request #{id}" if message == :closed
      raise RemoteError.new(message.fetch("error")) if message.key?("error")

      message["result"]
    end

    def request(method, params = nil, timeout: DEFAULT_TIMEOUT)
      await(send_request(method, params), timeout: timeout)
    end

    def notify(method, params = nil)
      write_raw(JSON.generate(frame(nil, method, params)))
    end

    def cancel_request(id) = notify(Methods::CANCEL_REQUEST, { "requestId" => id })

    # --- the protocol ---------------------------------------------------

    def initialize_agent(capabilities: Methods::BASELINE_CLIENT_CAPABILITIES, info: CLIENT_INFO, timeout: DEFAULT_TIMEOUT)
      result = request(Methods::INITIALIZE, {
        "protocolVersion" => Methods::PROTOCOL_VERSION, "clientCapabilities" => capabilities, "clientInfo" => info,
      }, timeout: timeout)
      @client_capabilities = capabilities
      @protocol_version = result["protocolVersion"]
      @agent_capabilities = result["agentCapabilities"]
      @agent_info = result["agentInfo"]
      @auth_methods = result["authMethods"] || []
      result
    end

    def authenticate(method_id) = request(Methods::AUTHENTICATE, { "methodId" => method_id })

    def new_session(cwd:, mcp_servers: [])
      request(Methods::SESSION_NEW, { "cwd" => cwd, "mcpServers" => mcp_servers })
    end

    def load_session(session, cwd:, mcp_servers: [])
      request(Methods::SESSION_LOAD, { "sessionId" => session, "cwd" => cwd, "mcpServers" => mcp_servers })
    end

    def resume_session(session, cwd:, mcp_servers: [])
      request(Methods::SESSION_RESUME, { "sessionId" => session, "cwd" => cwd, "mcpServers" => mcp_servers })
    end

    def close_session(session) = request(Methods::SESSION_CLOSE, { "sessionId" => session })

    def set_mode(session, mode_id) = request(Methods::SESSION_SET_MODE, { "sessionId" => session, "modeId" => mode_id })

    def set_config_option(session, config_id, value)
      request(Methods::SESSION_SET_CONFIG_OPTION, { "sessionId" => session, "configId" => config_id, "value" => value })
    end

    # A prompt as text (one block) or as content blocks; the turn is
    # collected from this moment.
    def start_prompt(session, prompt)
      blocks = prompt.is_a?(Array) ? prompt : [{ "type" => Methods::ContentBlock::TEXT, "text" => prompt }]
      id = @lock.synchronize do
        id = @next_id
        @next_id += 1
        @pending[id] = Queue.new
        @turn_marks[id] = [session, @updates.length, @requests_seen.length]
        id
      end
      write_raw(JSON.generate(frame(id, Methods::SESSION_PROMPT, { "sessionId" => session, "prompt" => blocks })))
      id
    end

    def finish_prompt(id, timeout: DEFAULT_TIMEOUT)
      result = await(id, timeout: timeout)
      session, updates_from, requests_from = @lock.synchronize { @turn_marks.delete(id) }
      updates, requests = @lock.synchronize { [@updates[updates_from..], @requests_seen[requests_from..]] }
      mine = updates.select { |params| params["sessionId"] == session }
      chunks = mine.select { |params| params.dig("update", Methods::SESSION_UPDATE_DISCRIMINATOR) == Methods::SessionUpdate::AGENT_MESSAGE_CHUNK }
      Turn.new(
        stop_reason: result.is_a?(Hash) ? result["stopReason"] : nil,
        updates: mine.map { |params| params.fetch("update").merge("sessionId" => session) },
        text: chunks.map { |params| params.dig("update", "content", "text").to_s }.join,
        permissions: requests.select { |seen| seen["method"] == Methods::SESSION_REQUEST_PERMISSION },
        elicitations: requests.select { |seen| seen["method"] == Methods::ELICITATION_CREATE }
      )
    end

    def prompt(session, prompt, timeout: DEFAULT_TIMEOUT) = finish_prompt(start_prompt(session, prompt), timeout: timeout)

    # `session/cancel`; every held permission request is answered
    # `cancelled` FIRST (the client's rule on the prompt-turn page) unless
    # the policy keeps them open to watch the agent's own cascade.
    def cancel(session)
      if @policy.fetch(:cancel_answers_held)
        held_permissions(session).each do |seen|
          answer_held(seen.fetch("id"), { "outcome" => { "outcome" => Methods::PermissionOutcome::CANCELLED } })
        end
      end
      notify(Methods::SESSION_CANCEL, { "sessionId" => session })
    end

    # --- what the agent did ---------------------------------------------

    # The first `session/update` of `kind` on `session`, waited for.
    def await_update(session, kind, timeout: DEFAULT_TIMEOUT)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        found = @lock.synchronize do
          @updates.find { |params| params["sessionId"] == session && params.dig("update", Methods::SESSION_UPDATE_DISCRIMINATOR) == kind }
        end
        return found if found
        raise Unanswered, "no #{kind} on #{session} within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL_SECONDS
      end
    end

    # The next request the policy held open (its `requests_seen` entry;
    # `answer` fills in when it is answered).
    def await_held(timeout: DEFAULT_TIMEOUT)
      seen = @held_queue.pop(timeout: timeout)
      raise Unanswered, "no request was held within #{timeout}s" if seen.nil?

      seen
    end

    def answer_held(id, result)
      seen = @lock.synchronize { @held.delete(id) }
      raise Error, "request #{id} is not held" unless seen

      answer(seen, result)
    end

    def fail_held(id, code, message)
      seen = @lock.synchronize { @held.delete(id) }
      raise Error, "request #{id} is not held" unless seen

      fail_request(seen, code, message)
    end

    # --- the editor's buffers ---------------------------------------------

    # The table as it stands: what the agent wrote through the port shows here.
    def buffers = @lock.synchronize { @buffers }

    def buffer(path) = buffers[path.to_s]

    # A buffer set by the test (an editor typing); the table is replaced.
    def set_buffer(path, text)
      @lock.synchronize { @buffers = @buffers.merge(path.to_s => text.to_s).freeze }
      nil
    end

    # Every `fs/*` request the agent made, oldest first, with its answer.
    def fs_requests
      @lock.synchronize { @requests_seen.select { |seen| FS_FLAGS.key?(seen["method"]) } }
    end

    # --- the process ------------------------------------------------------

    # EOF on the agent's stdin and nothing else: the test then reads the
    # exit the agent chooses on its own (`wait_exit`), where `close` would
    # end the group after a bounded wait.
    def end_input
      @io.close_write
      nil
    rescue IOError, Errno::EPIPE
      nil
    end

    def alive?
      return false if @exit_status

      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def wait_exit(timeout: DEFAULT_TIMEOUT)
      return @exit_status if @exit_status

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        _, status = Process.waitpid2(@pid, Process::WNOHANG)
        return @exit_status = status if status
        raise Unanswered, "the agent (pid #{@pid}) did not exit within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL_SECONDS
      end
    rescue Errno::ECHILD
      @exit_status
    end

    def stderr
      return "" unless @stderr_path && File.file?(@stderr_path)

      File.read(@stderr_path, encoding: Encoding::UTF_8).scrub
    end

    # EOF on the agent's stdin, a bounded wait, then the group ladder for
    # an agent that stays; idempotent.
    def close
      return if @closed

      @closed = true
      begin
        @io.close_write
      rescue IOError, Errno::EPIPE
        nil
      end
      begin
        wait_exit(timeout: EXIT_WAIT_SECONDS)
      rescue Unanswered
        ProcessRunner.terminate(@pid)
        @exit_status ||= :terminated
      end
      begin
        @io.close
      rescue IOError, Errno::ECHILD
        nil
      end
      @reader.join(1)
      nil
    end

    private

      def frame(id, method, params)
        message = { "jsonrpc" => Methods::JSONRPC }
        message["id"] = id unless id.nil?
        message["method"] = method
        message["params"] = params unless params.nil?
        message
      end

      def read_loop
        while (line = @io.gets)
          @lock.synchronize { @stdout_lines << line.chomp }
          handle(line)
        end
      rescue IOError, Errno::EBADF
        nil
      ensure
        finish
      end

      def finish
        queues = @lock.synchronize { @pending.values.tap { @pending.clear } }
        queues.each { |queue| queue << :closed }
        @held_queue << nil
      end

      def handle(line)
        message = JSON.parse(line.strip)
        return unless message.is_a?(Hash)

        if message["method"].is_a?(String)
          message["id"].nil? ? notification(message) : inbound(message)
        elsif message.key?("result") || message.key?("error")
          response(message)
        end
      rescue JSON::ParserError
        nil
      end

      def response(message)
        id = message["id"]
        return @lock.synchronize { @stray_failures << message } if id.nil?

        queue = @lock.synchronize do
          queue = @pending.delete(id)
          @unclaimed[id] = message unless queue
          queue
        end
        queue&.push(message)
      end

      def notification(message)
        params = message["params"]
        case message["method"]
        when Methods::SESSION_UPDATE then @lock.synchronize { @updates << params }
        when Methods::CANCEL_REQUEST then cancel_notice(params.is_a?(Hash) ? params["requestId"] : nil)
        else nil
        end
      end

      # The agent's cascade: a held request is answered -32800, an
      # answered or unknown one is ignored; every notice is recorded.
      def cancel_notice(id)
        seen = @lock.synchronize do
          @cancel_notices << id
          @held.delete(id)
        end
        fail_request(seen, Methods::ErrorCode::REQUEST_CANCELLED, Methods::ErrorCode::MESSAGES.fetch(Methods::ErrorCode::REQUEST_CANCELLED)) if seen
      end

      def inbound(message)
        seen = { "id" => message["id"], "method" => message["method"], "params" => message["params"], "answer" => nil }
        @lock.synchronize { @requests_seen << seen }
        case message["method"]
        when Methods::SESSION_REQUEST_PERMISSION then decide(seen, :permission)
        when Methods::ELICITATION_CREATE then decide(seen, :elicitation)
        when Methods::FS_READ_TEXT_FILE then serve_fs(seen) { |params| read_buffer(params) }
        when Methods::FS_WRITE_TEXT_FILE then serve_fs(seen) { |params| write_buffer(params) }
        else
          fail_request(seen, Methods::ErrorCode::METHOD_NOT_FOUND, Methods::ErrorCode::MESSAGES.fetch(Methods::ErrorCode::METHOD_NOT_FOUND))
        end
      end

      # An fs method is served only under the flag this client advertised
      # at `initialize`; the block answers a result, or a code for the
      # client's own error (`not_found`).
      def serve_fs(seen)
        unless fs_advertised?(seen.fetch("method"))
          return fail_request(seen, Methods::ErrorCode::METHOD_NOT_FOUND, Methods::ErrorCode::MESSAGES.fetch(Methods::ErrorCode::METHOD_NOT_FOUND))
        end

        result = yield(seen.fetch("params").to_h)
        return fail_request(seen, result, Methods::ErrorCode::MESSAGES.fetch(result)) if result.is_a?(Integer)

        answer(seen, result)
      end

      def fs_advertised?(method)
        @client_capabilities.to_h.dig("fs", FS_FLAGS.fetch(method)) == true
      end

      # `{content}`: the buffer from `line` (1-based; the whole buffer when
      # absent) for at most `limit` lines; a path not held is -32002.
      def read_buffer(params)
        text = buffer(params["path"])
        return Methods::ErrorCode::RESOURCE_NOT_FOUND if text.nil?

        lines = text.lines
        from = params["line"].is_a?(Integer) && params["line"].positive? ? params["line"] - 1 : 0
        window = params["limit"].is_a?(Integer) ? lines[from, params["limit"]] : lines[from..]
        { "content" => Array(window).join }
      end

      def write_buffer(params)
        set_buffer(params["path"], params["content"])
        {}
      end

      def decide(seen, kind)
        policy = @policy.fetch(kind)
        if policy == :hold
          @lock.synchronize { @held[seen.fetch("id")] = seen }
          @held_queue << seen
          return
        end

        result = policy.respond_to?(:call) ? policy.call(seen.fetch("params")) : scripted(kind, policy, seen.fetch("params"))
        answer(seen, result)
      end

      def scripted(kind, policy, params)
        kind == :permission ? permission_answer(policy, params) : elicitation_answer(policy)
      end

      # `:allow` → the first allow option, `:reject` → the first reject
      # option, `:cancel` → the cancelled outcome; no option of the kind →
      # cancelled (harbor's rule).
      def permission_answer(policy, params)
        wanted = wanted_option_kinds(policy)
        option = Array(params["options"]).find { |candidate| wanted.include?(candidate["kind"]) }
        return { "outcome" => { "outcome" => Methods::PermissionOutcome::CANCELLED } } unless option

        { "outcome" => { "outcome" => Methods::PermissionOutcome::SELECTED, "optionId" => option.fetch("optionId") } }
      end

      def wanted_option_kinds(policy)
        case policy
        when :allow then [Methods::PermissionOptionKind::ALLOW_ONCE, Methods::PermissionOptionKind::ALLOW_ALWAYS]
        when :reject then [Methods::PermissionOptionKind::REJECT_ONCE, Methods::PermissionOptionKind::REJECT_ALWAYS]
        when :cancel then []
        else raise ArgumentError, "unknown permission policy #{policy.inspect}"
        end
      end

      def elicitation_answer(policy)
        case policy
        when :accept then { "action" => Methods::ElicitationAction::ACCEPT, "content" => { "answer" => "yes" } }
        when :decline then { "action" => Methods::ElicitationAction::DECLINE }
        when :cancel then { "action" => Methods::ElicitationAction::CANCEL }
        else raise ArgumentError, "unknown elicitation policy #{policy.inspect}"
        end
      end

      def held_permissions(session)
        @lock.synchronize do
          @held.values.select { |seen| seen["method"] == Methods::SESSION_REQUEST_PERMISSION && seen.dig("params", "sessionId") == session }
        end
      end

      def answer(seen, result)
        seen["answer"] = result
        write_raw(JSON.generate({ "jsonrpc" => Methods::JSONRPC, "id" => seen.fetch("id"), "result" => result }))
      end

      def fail_request(seen, code, message)
        seen["answer"] = { "code" => code, "message" => message }
        write_raw(JSON.generate({ "jsonrpc" => Methods::JSONRPC, "id" => seen.fetch("id"), "error" => { "code" => code, "message" => message } }))
      end
  end
end
