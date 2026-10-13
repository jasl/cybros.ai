require "faraday"
require "mcp"
require "rho/runner"

module Rho
  module Mcp
    # ONE CONNECTION PER SERVER: the SDK's
    # `MCP::Client` on one transport, connected `:auto` at LOAD under the
    # startup bound (the stdio transport's read timeout, set for the
    # connect and the list and CLEARED after; Faraday's `open_timeout` for
    # http), its tools listed ONCE — the announced set for the daemon's
    # life.
    #
    # ONE REQUEST IN FLIGHT ON STDIO: the SDK's stdio reader reads the
    # shared stdout with no reader lock and DISCARDS every frame whose id
    # is not its own, so two parallel calls on one pipe tear each other's
    # frames. A MUTEX around every stdio request; a queued sibling waits
    # under its own park clock, and one that was cancelled while waiting
    # runs nothing. HTTP takes no mutex: each POST is its own stream.
    #
    # THE RECOVERY PATH, BOUNDED, TIED TO A CALL: a server whose exit is RECORDED before a
    # call — the watcher saw it leave, rho-mcp killed it after a cancelled
    # or timed-out call, or (http) the last request's transport error
    # marked the connection unreachable — is restarted ONCE for that call
    # and the result opens with a notice line the model reads; a restart
    # that fails answers `failed` naming both, and the next call tries
    # once again. A server that dies UNDER a call answers `failed` naming
    # the exit; the lost call is NOT retried (a worst-case write may have
    # partially run). The ONE exception is a legacy http session's expiry:
    # the server itself says the request was never processed, so the
    # session is re-established and the call resent once, with a notice.
    # A CANCELLED OR TIMED-OUT CALL POISONS A STDIO CONNECTION — the SDK's
    # abandoned reader stays on the pipe and eats the next frame whether
    # the server honours the cancel or ignores it — so the connection
    # KILLS the group and reaps it (no graceful stage: the runner's clamp
    # leaves the handler two seconds), records the kill, and the next
    # call restarts it. HTTP is
    # unaffected: the cancel notification rides its own POST and the
    # abandoned worker returns at Faraday's read timeout.
    #
    # THE MODEL-READ SURFACE IS REDACTED BY VALUE: every result a call maps and every body a load answers
    # passes the row's `Redact` — its text and its structure — before the
    # notice opens it, the same set the failure sentences, the stderr
    # tail and the log pass through. A server that echoes the token it
    # was handed, in its text or in `structuredContent`, hands the model
    # `•••`. A capture is image or PDF bytes on disk under the artifacts
    # dir (`Mapping::CAPTURE_EXTENSIONS`): binary content is not walked.
    #
    # AN OAUTH ROW carries a `storage:`
    # where this host has a home. At each `open!` the storage is asked:
    # tokens held ⇒ the HEADLESS provider rides the transport (the stored
    # token on every request, the gem's refresh on a 401); none ⇒ no
    # provider, and a 401 is classified from its challenge alone, no
    # network. A refusal the gem raises under a call is decided by the
    # STORE's state after the gem returns, never by the error's class: a
    # refresh token still held is a renewal failure the next call retries
    # (the http row's unreachable path); tokens gone is a needed login; a
    # recorded step-up is a needed login naming the union. `revive!` on a
    # login-shaped record reads the FILE first and reconnects only when a
    # login was performed meanwhile — no network for a row nobody logged
    # in to. A credential file rho refuses to read is its own kind, never
    # spelled "needs login". An OAuth row WITH ITS PROVIDER ATTACHED is
    # SERIALIZED like a stdio row: two requests meeting one 401 would both
    # present the same refresh token, and the rotated second one would log
    # a fine row out; a row holding no tokens can refresh nothing and keeps
    # the http fan. The provider also serializes the actual OAuth flow:
    # cancellation can release the caller before its HTTP worker returns.
    class Connection
      CLIENT_INFO = { name: "rho-mcp", version: Rho::Mcp::VERSION }.freeze
      # How long the watcher may lag the error it caused: the SDK's reader
      # sees the closed pipe a beat before the leader is reaped.
      WATCHER_GRACE_SECONDS = 1.0

      # What is known of the exit: `kind` is `:exited` (the watcher),
      # `:killed` (rho-mcp's own act after a timed-out call, `tool` naming
      # the call), `:unreachable` (http: the last request's transport
      # error, `description` quoting it), `:login_required` (an OAuth row
      # whose tokens are gone or whose step-up stands, `description` the
      # `down:` sentence naming the verb) or `:credential_file` (a
      # credential file rho refuses to read, `description` the core
      # sentence); the phrase is the notice's and `rho mcp`'s.
      ExitRecord = Data.define(:kind, :description, :tail, :at, :tool) do
        def phrase
          stamp = at.strftime("%H:%M:%S")
          case kind
          when :killed then "been stopped after a timed-out call (#{tool})"
          when :unreachable then "stopped answering (#{description} at #{stamp})"
          when :login_required then "needed a login"
          when :credential_file then "refused its credential file (#{description})"
          else "exited (#{description} at #{stamp}#{Mapping.tail_clause(tail)})"
          end
        end

        # The `down:` line on `rho mcp`.
        def down
          stamp = at.strftime("%H:%M:%S")
          case kind
          when :killed then "killed after a timed-out call (#{tool}) at #{stamp}"
          when :unreachable then "unreachable (#{description}) at #{stamp}"
          when :login_required then description
          when :credential_file then "#{description} — rho refuses to read it"
          else "exited (#{description}) at #{stamp}"
          end
        end

        def login_shaped? = kind == :login_required || kind == :credential_file
      end

      attr_reader :key, :row, :tools, :prompts, :resources, :connected_at, :storage
      # The last no-token 401 `open!` classified (the verb's first phase).
      attr_reader :challenge

      def initialize(row, log: nil, redact: Rho::Runner::Redact.new, transport_factory:, clock: -> { Time.now }, storage: nil)
        @row = row
        @key = row.key
        @log = log
        @redact = redact
        @transport_factory = transport_factory
        @clock = clock
        @storage = storage
        @provider = nil
        @challenge = nil
        @mutex = Mutex.new
        @authorization_mutex = Mutex.new
        @lifecycle_mutex = Mutex.new
        @closed = false
        @transport = nil
        @client = nil
        @tools = []
        @prompts = []
        @resources = []
        @killed = nil
        @connected_at = nil
      end

      # Connect under the startup bound. The opener owns the transport until
      # publication; a concurrent close or interrupted startup releases it.
      def open!(list: true)
        check_open
        published = false
        provider = attach_provider
        transport = @transport_factory.call(@row, read_timeout: @row.startup_timeout_ms / 1000.0, oauth: provider)
        client = MCP::Client.new(transport: transport)
        @provider = provider
        begin
          client.connect(mode: :auto, client_info: CLIENT_INFO, capabilities: {})
          listed = list ? client.tools : @tools
          prompts, resources = list ? listings(client) : [@prompts, @resources]
        rescue StandardError => error
          sentence = startup_failure(transport, error)
          raise Unavailable, sentence
        ensure
          transport.read_timeout = nil
        end
        published = @lifecycle_mutex.synchronize do
          next false if @closed

          @transport = transport
          @client = client
          @tools = listed
          @prompts = prompts
          @resources = resources
          @killed = nil
          @connected_at = @clock.call
          true
        end
        unless published
          raise Closed, "mcp server #{@key} is closed"
        end
        self
      ensure
        close_quietly(transport) if transport && !published
      end

      def connected? = !@transport.nil? && exit_record.nil?

      # A stdio child's pid and group; nil for a transport with no process,
      # or none held.
      def pid = @transport&.pid

      def group_pid = @transport&.group_pid

      def protocol_version = @client&.protocol_version

      def server_name = @client&.server_implementation&.dig("name")

      def server_version = @client&.server_implementation&.dig("version")

      def instructions = @client&.instructions

      def server_capabilities = @client&.server_capabilities

      # The recorded exit, if any: rho-mcp's own record (a kill, an
      # unreachable http server), else the watcher's.
      def exit_record
        return @killed if @killed
        return nil unless @transport&.exited?

        ExitRecord.new(kind: :exited, description: @transport.exit_description,
          tail: @redact.call(@transport.stderr_tail), at: @transport.exited_at || @clock.call, tool: nil)
      end

      # `down` for `rho mcp`: nil while connected.
      def down = exit_record&.down

      # The storage's read-only state for the report; nil for a row with
      # none (a homeless host, a non-OAuth row).
      def auth_status = @storage&.status

      # THE CALL. Answers a `Result`; a cancelled call answers NOTHING and
      # returns through the runner's own checkpoint (`raise_if_cancelled!`
      # — the pool reads a handler's plain return as its answer, so the
      # deadline must be raised, as `bash` raises it, for the task run to
      # answer the clamp as data); raises `ServerGone` / `CallRefused` for
      # `outcome: failed`.
      def call_tool(raw_name, arguments, public_name:, env: nil)
        serialized do
          checkpoint!
          notice = revive!(public_name)
          exchange(public_name, notice) do |cancellation, opening|
            response = @client.call_tool(name: raw_name, arguments: arguments, cancellation: cancellation)
            result = Mapping.result(response["result"], server: @key, redact: @redact, env: env)
            Mapping.with_notice(result, opening)
          end
        end
      end

      # THE LOAD OF A PROMPT this server announced as a document:
      # `prompts/get` with no arguments (a prompt with a required one was
      # never announced) → the messages' text as the body. Serialized,
      # revived and judged as a call is; `name` is the document's announced
      # name, the one the model typed and the sentences name.
      def load_prompt(raw_name, name:, env: nil)
        load_document(name) do |cancellation|
          raw = @client.get_prompt(name: raw_name, cancellation: cancellation)
          Documents.prompt_result(raw, server: @key, name: name, env: env)
        end
      end

      # THE LOAD OF A RESOURCE: `resources/read` by the URI the listing
      # carried → the contents as the body (text verbatim; an image or PDF blob a
      # capture under `env`'s artifacts dir).
      def load_resource(uri, name:, env: nil)
        load_document(name) do |cancellation|
          contents = @client.read_resource(uri: uri, cancellation: cancellation)
          Documents.resource_result(contents, server: @key, name: name, env: env)
        end
      end

      # The resource templates the probe prints (`resources/templates/list`);
      # a template is not a document by construction.
      def resource_templates
        return [] unless capability?(@client, "resources")

        serialized { Array(@client.resource_templates) }
      end

      # The ladder, outside any lock (`Rho::Mcp.close!` takes the
      # connections out under its own and closes them in parallel).
      def close
        transport = @lifecycle_mutex.synchronize do
          @closed = true
          held = @transport
          @transport = nil
          @client = nil
          held
        end
        transport&.close
      end

      private

        # A stdio row is a process with one pipe: the mutex, the ladder,
        # the poison rule. An http row is none of those — but one with its
        # OAuth provider attached takes the mutex too (the rotation rule,
        # the class comment).
        def process? = @row.stdio?

        def serialized(&request)
          operation = lambda do
            check_open
            request.call
          end
          process? || !@provider.nil? ? @mutex.synchronize(&operation) : operation.call
        end

        def check_open
          raise Closed, "mcp server #{@key} is closed" if @lifecycle_mutex.synchronize { @closed }
        end

        # The headless provider, only when the storage holds tokens; a
        # credential file rho refuses to read is `Unavailable` with its
        # own sentence and its own record.
        def attach_provider
          return nil if @storage.nil?

          tokens = @storage.tokens
          tokens ? Oauth::Provider.headless(row: @row, storage: @storage, authorization_mutex: @authorization_mutex) : nil
        rescue Oauth::CredentialFile => error
          @killed = ExitRecord.new(kind: :credential_file, description: error.message, tail: "", at: @clock.call, tool: nil)
          @log&.error("mcp.oauth.credential_file", server: @key, reason: error.message)
          raise Unavailable, @killed.down
        end

        # The lists at load, each only where the server's capabilities name
        # it (`prompts`, `resources` — `initialize`'s `capabilities` in both
        # eras); every page, as `tools` is drained.
        def listings(client)
          [capability?(client, "prompts") ? Array(client.prompts) : [],
           capability?(client, "resources") ? Array(client.resources) : []]
        end

        def capability?(client, name)
          capabilities = client.server_capabilities.to_h
          capabilities.key?(name) || capabilities.key?(name.to_sym)
        end

        # A document's load: the same mutex, checkpoint, revival and
        # exchange as a call, the request the block's; the envelope is the
        # `skill` row's: a name the server no longer holds answers
        # `skill_unknown`, a load asking for input `skill_unavailable`.
        def load_document(name)
          serialized do
            checkpoint!
            notice = revive!(name)
            exchange(name, notice, document: name) do |cancellation, opening|
              Mapping.with_notice(scrubbed(yield(cancellation)), opening)
            end
          end
        end

        # The result as the model and the UI read it, every expanded secret
        # replaced by value (the header's rule).
        def scrubbed(result)
          result.with(content: @redact.call(result.content),
            structured_content: @redact.structure(result.structured_content))
        end

        # THE ONE EXCHANGE: the request under the cancel bridge, judged by
        # the two-axis law; `opening` is the notice the result opens with,
        # grown by a session renewal. `renewed` guards the resend: once.
        # `document` names a `skill` load, whose refusals are the load's
        # envelope rather than a call's.
        def exchange(public_name, opening, renewed: false, document: nil, &request)
          with_cancellation { |cancellation| request.call(cancellation, opening) }
        rescue MCP::CancelledError
          poison!(public_name) if process?
          checkpoint!
          nil
        rescue MCP::Client::SessionExpiredError => error
          raise ServerGone, session_lost(public_name, error) if renewed

          exchange(public_name, renew_session!(public_name, opening), renewed: true, document: document, &request)
        rescue MCP::Client::ServerError => error
          refused(error, public_name, opening, document: document)
        rescue MCP::Client::InputRequiredError
          raise CallRefused, "mcp server #{@key}'s #{public_name} asks for input this client does not provide" if document.nil?

          Mapping.with_notice(Rho::Runner::Result.error("skill_unavailable: #{document} asks for input this client " \
                                                        "does not provide"), opening)
        rescue MCP::Client::RequestHandlerError => error
          raise ServerGone, died_under_call(public_name, error)
        rescue MCP::Client::OAuth::Flow::AuthorizationError => error
          refused_by_the_store(public_name, error)
        rescue Oauth::CredentialFile => error
          raise CallRefused, credential_file_under_call(public_name, error)
        end

        # THE REFUSAL UNDER A CALL, DECIDED BY THE STORE: the gem
        # raised inside its own 401 rescue (the validator refused, or
        # discovery failed), and the file — no network — says which of the
        # three it was.
        def refused_by_the_store(public_name, error)
          pending = @storage&.pending_scope
          raise CallRefused, login_required_under_call(public_name, pending: pending) if pending
          raise ServerGone, renewal_failed_under_call(public_name, error) if @storage&.tokens

          raise CallRefused, login_required_under_call(public_name, pending: nil)
        rescue Oauth::CredentialFile => file_error
          raise CallRefused, credential_file_under_call(public_name, file_error)
        end

        # Tokens still held: the refresh failed for a reason the gem kept to
        # itself (transient by its own classification — the refresh token
        # was NOT cleared), or discovery failed after it. The http row's
        # existing unreachable path: the next call reconnects, the gem
        # refreshes again. No verb is named.
        def renewal_failed_under_call(public_name, error)
          reason = renewal_reason(error)
          @killed = ExitRecord.new(kind: :unreachable, description: "could not renew its authorization (#{reason})",
            tail: "", at: @clock.call, tool: public_name)
          @log&.warn("mcp.oauth.renewal_failed", server: @key, tool: public_name, reason: reason)
          "mcp server #{@key} stopped answering during #{public_name}: could not renew its authorization (#{reason}); " \
            "the next call reconnects"
        end

        # The gem's `attempt_refresh` swallows the refresh's own error before
        # running the full flow the validator refuses, so a refusal carries
        # no status; any other `AuthorizationError` is the gem's sentence.
        def renewal_reason(error)
          if error in MCP::Client::OAuth::Flow::AuthorizationRefusedError
            "the authorization server did not accept the refresh; the refresh token is kept"
          else
            @redact.call(error.message.to_s.chomp("."))
          end
        end

        # Tokens gone (the gem's `invalid_grant` arm cleared them) or never
        # held, or a step-up recorded: the record, the log line, the
        # model-facing sentence — codex's words first.
        def login_required_under_call(public_name, pending:)
          reason = pending ? "scope step-up (#{pending})" : "tokens cleared (the refresh was rejected)"
          @killed = ExitRecord.new(kind: :login_required, description: "needs login — run `rho mcp login #{@key}`",
            tail: "", at: @clock.call, tool: public_name)
          @log&.warn("mcp.oauth.login_required", server: @key, tool: public_name, reason: reason)
          login_sentence(pending: pending)
        end

        def login_sentence(pending:)
          verb = "ask the person to run `rho mcp login #{@key}`"
          tail = "every call to mcp__#{@key}__* fails until then"
          if pending
            granted = @storage.tokens&.dig("scope").to_s.split
            required = (pending.split - granted).join(" ")
            "mcp server #{@key}: authentication required — it now requires scope #{required} (granted: " \
              "#{granted.join(" ")}) and this process cannot log in; #{verb} (which asks for #{pending}); #{tail}"
          else
            "mcp server #{@key}: authentication required — its authorization was rejected and this process cannot " \
              "log in; #{verb}; #{tail}"
          end
        end

        def credential_file_under_call(public_name, error)
          @killed = ExitRecord.new(kind: :credential_file, description: error.message, tail: "", at: @clock.call,
            tool: public_name)
          @log&.error("mcp.oauth.credential_file", server: @key, reason: error.message)
          "mcp server #{@key}: #{error.message} — ask the person to chmod it; every call to mcp__#{@key}__* fails until then"
        end

        # -32602 is the spec's code for BOTH "unknown tool" and invalid
        # arguments, and servers validate more than the schema: the server's
        # words reach the model as `is_error` data it self-corrects on (the
        # spec's MAY); every other code is `failed`. For a DOCUMENT the
        # same code says the prompt or resource is not what was listed (it
        # vanished since load, or asks for arguments now): `skill_unknown`,
        # the one word the kernel's own branch produces.
        def refused(error, public_name, notice, document: nil)
          message = @redact.call(error.message.to_s)
          if error.code == -32602
            body = document ? "skill_unknown: #{document}" : "The server refused the call: #{message}"
            return Mapping.with_notice(Rho::Runner::Result.error(body), notice)
          end

          raise CallRefused, "mcp server #{@key} answered #{public_name} with error #{error.code}: #{message}"
        end

        # The runner's checkpoint: a cancelled context raises `Cancelled`
        # with its reason (`:deadline` → the clamp's answer, else
        # "interrupted"); outside a context (the probe) nothing raises.
        def checkpoint!
          Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
        end

        def with_cancellation
          cancellation = MCP::Cancellation.new
          on_cancel = -> { cancellation.cancel(reason: "the runner cancelled the call") }
          Rho::Runner::ExecutionContext.with_cancel_signal(on_cancel) { yield cancellation }
        end

        # A LEGACY SESSION'S EXPIRY IS NOT A DEATH: the gem cleared the session on the 404; "per
        # spec, clients MUST start a new session with a fresh initialize" — the same transport
        # handshakes again, and the call is resent ONCE under the notice. A handshake that fails
        # marks the server unreachable, so the next call reconnects and reports that the
        # connection restarted.
        def renew_session!(public_name, opening)
          @client.connect(mode: :auto, client_info: CLIENT_INFO, capabilities: {})
          @log&.info("mcp.session_renewed", server: @key, tool: public_name)
          line = "note: mcp server #{@key}'s session had expired and was re-established for this call"
          [opening, line].compact.join("\n")
        rescue MCP::Client::RequestHandlerError => error
          message = describe(error)
          mark_unreachable(public_name, message)
          raise ServerGone, "mcp server #{@key}'s session had expired during #{public_name} and could not be " \
                            "re-established: #{message}; the next call reconnects"
        end

        def session_lost(public_name, error)
          message = describe(error)
          mark_unreachable(public_name, message)
          "mcp server #{@key}'s session expired again during #{public_name}, after being re-established once: " \
            "#{message}; the next call reconnects"
        end

        # A server known dead at call time: restart ONCE for this call,
        # the notice line, or `ServerGone` naming both the exit and the
        # spawn error — no `down` state that needs a boot to clear. A dead
        # http transport is dropped, never closed: its DELETE would wait
        # on the very host that stopped answering.
        def revive!(public_name)
          record = exit_record
          return nil if record.nil?

          still_refused!(public_name) if record.login_shaped?
          close_quietly(@transport) if process?
          begin
            open!(list: false)
          rescue Unavailable => error
            raise ServerGone, "mcp server #{@key} had #{record.phrase}; #{process? ? "restarting" : "reconnecting"} " \
                              "it for #{public_name} failed: #{error.message}; the next call tries again"
          end
          @log&.info("mcp.server_restarted", server: @key, tool: public_name, after: record.kind)
          "note: mcp server #{@key} had #{record.phrase} and was #{process? ? "restarted" : "reconnected"} for " \
            "this call; any state it held is gone"
        end

        # A login-shaped record reads the FILE first (no network): a standing
        # step-up or no tokens is the same refusal again; a credential file
        # still unreadable likewise; tokens present (a login performed
        # meanwhile) fall through to the reconnect with its notice.
        def still_refused!(public_name)
          return if @storage.nil?

          status = @storage.status
          raise CallRefused, credential_file_under_call(public_name, Oauth::CredentialFile.new(status.reason)) if
            status.state == :credential_file

          pending = @storage.pending_scope
          raise CallRefused, login_required_under_call(public_name, pending: pending) if pending
          raise CallRefused, login_required_under_call(public_name, pending: nil) unless status.logged_in?
        end

        # The poison rule: the group KILLED and reaped at once (`bash`'s
        # cancel precedent — the ladder is shutdown's; the runner's clamp
        # gives this handler 2 s to return), the kill recorded as if the
        # watcher saw it, the next call restarts.
        def poison!(public_name)
          kill_quietly(@transport)
          @transport = nil
          @client = nil
          @killed = ExitRecord.new(kind: :killed, description: "killed", tail: "", at: @clock.call, tool: public_name)
          @log&.warn("mcp.server_killed", server: @key, tool: public_name,
            reason: "the call was cancelled or timed out; a stdio connection cannot be reused past an abandoned read")
        end

        def died_under_call(public_name, error)
          return unreachable_under_call(public_name, error) unless process?

          settle(@transport)
          record = exit_record
          tail = @redact.call(@transport.stderr_tail)
          close_quietly(@transport)
          @transport = nil
          @client = nil
          if record
            @killed = record
            @log&.warn("mcp.server_exited", server: @key, tool: public_name, exit: record.description)
            "mcp server #{@key} exited (#{record.description}) during #{public_name}" \
              "#{Mapping.tail_clause(tail)}; the next call restarts it"
          else
            @killed = ExitRecord.new(kind: :exited, description: "transport failed", tail: tail, at: @clock.call,
              tool: public_name)
            @log&.warn("mcp.server_exited", server: @key, tool: public_name, exit: "transport failed")
            "mcp server #{@key} stopped answering during #{public_name}: #{describe(error)}" \
              "#{Mapping.tail_clause(tail)}; the next call restarts it"
          end
        end

        # An http server's transport error under a call: the connection is
        # marked unreachable (the next call reconnects, with the notice)
        # and the call fails naming what Faraday saw.
        def unreachable_under_call(public_name, error)
          message = describe(error)
          mark_unreachable(public_name, message)
          "mcp server #{@key} stopped answering during #{public_name}: #{message}; the next call reconnects"
        end

        def mark_unreachable(public_name, message)
          @killed = ExitRecord.new(kind: :unreachable, description: message, tail: "", at: @clock.call, tool: public_name)
          @log&.warn("mcp.server_unreachable", server: @key, tool: public_name, reason: message)
        end

        # The gem wraps a Faraday error in "Internal error handling …"
        # (`RequestHandlerError#original_error`, the session's expiry a
        # subclass); the sentence names what Faraday saw, redacted.
        def describe(error)
          original = error.original_error
          text = original ? "#{original.class.name.to_s.split("::").last}: #{original.message}" : error.message.to_s
          @redact.call(text)
        end

        def startup_failure(transport, error)
          message = @redact.call(error.message.to_s)
          if settle(transport)
            tail = @redact.call(transport.stderr_tail)
            return "exited (#{transport.exit_description}) during startup#{Mapping.tail_clause(tail)}"
          end
          case error
          in MCP::Client::RequestHandlerError
            return "did not answer within #{@row.startup_timeout_ms} ms" if message.include?("Timed out")

            (http_startup_failure(error) if @row.http?) || "could not connect: #{message}"
          in MCP::Client::OAuth::Flow::AuthorizationError then oauth_startup_failure(error)
          in Oauth::CredentialFile
            @log&.error("mcp.oauth.credential_file", server: @key, reason: error.message)
            "#{error.message} — rho refuses to read it"
          else
            "could not list its tools: #{message}"
          end
        end

        # What Faraday saw, when the gem wrapped it: a refused or timed-out
        # connect, a read that ran past the park — or the no-token 401,
        # classified from its challenge, the log line at WARN when
        # it names the verb.
        def http_startup_failure(error)
          original = error.original_error
          return nil if original.nil?
          return "did not answer within #{@row.timeout_ms} ms" if original in Faraday::TimeoutError
          return unauthorized_at_startup(error) if Oauth::Challenge.unauthorized?(error)

          "could not connect to #{@row.url}: #{describe(error)}"
        end

        def unauthorized_at_startup(error)
          @challenge = Oauth::Challenge.classify(error)
          @log&.warn("mcp.oauth.login_required", server: @key, reason: "no tokens") if @challenge.oauth?
          @challenge.sentence(@key, home: !@storage.nil?)
        end

        # A refusal WITH tokens held at connect: the store's reading in
        # `down:` form — on the probe's read-only view the one
        # sentence that names the clock.
        def oauth_startup_failure(error)
          pending = @storage&.pending_scope
          if pending
            @log&.warn("mcp.oauth.login_required", server: @key, reason: "scope step-up (#{pending})")
            return "needs login — run `rho mcp login #{@key}`"
          end
          return probe_refusal if @storage&.read_only? && @storage.tokens
          return "unreachable (could not renew its authorization: #{renewal_reason(error)})" if @storage&.tokens

          @log&.warn("mcp.oauth.login_required", server: @key, reason: "tokens cleared (the refresh was rejected)")
          "needs login — run `rho mcp login #{@key}`"
        rescue Oauth::CredentialFile => file_error
          "#{file_error.message} — rho refuses to read it"
        end

        def probe_refusal
          issued = @storage.issued_at
          expires_in = Integer(@storage.tokens&.dig("expires_in"), exception: false)
          clock = if issued && expires_in
            past = @clock.call > issued + expires_in
            " (issued #{issued.localtime.strftime("%H:%M:%S")}, expires_in #{expires_in} — #{past ? "past" : "within"} its time)"
          else
            ""
          end
          "logged in; the access token was not accepted#{clock} and this verb does not renew it; the daemon renews " \
            "at its next call, or run `rho mcp login #{@key}`"
        end

        # The watcher may lag the error it caused by a beat, and the stderr
        # drain the exit: a real transport settles both under the bound
        # and answers whether it exited; a transport with no process
        # answers false at once.
        def settle(transport) = transport.settle(WATCHER_GRACE_SECONDS)

        def close_quietly(transport)
          transport&.close
        rescue StandardError
          nil
        end

        def kill_quietly(transport)
          transport&.kill
        rescue StandardError
          nil
        end
    end
  end
end
