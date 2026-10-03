require "cybros_agent"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "core/conversations"
require_relative "core/events"
require_relative "core/loops"
require_relative "core/memory"
require_relative "core/records"
require_relative "core/scheduled_jobs"
require_relative "core/workspaces"

module Rho
  # THE CORE: the capabilities every surface
  # consumes, over the daemon's control routes and the kernel. One method
  # is ONE capability over ONE route: it builds the body, sends one
  # request, parses, and answers the document or raises `Rho::Error` with
  # the daemon's sentence (a refusal as `Refused`, the code word and the
  # status beside it). No printing, no polling loop, no composition,
  # no exit code — those are the surfaces' (exe/rho and `Rho::Cli::*`,
  # rho-dev, later the TUI/ACP/IM). `test/code_style/core_surface_test.rb`
  # pins the surface and the two laws (nothing prints or waits here;
  # nothing outside reaches the daemon but through a named primitive).
  #
  # This file is the client (the door, the three verbs, the budgets), the
  # ceremony halves, the facts and where the tools are pointed; the
  # conversation, loop and record primitives are the three mixins beside it.
  class Core
    include Conversations
    include Events
    include Loops
    include Memory
    include Records
    include ScheduledJobs
    include Workspaces

    # What `loop_events` raises when the socket's deadline fires: a
    # surface tells a timeout from a refusal by class, never by sentence.
    class Deadline < Rho::Error; end

    # THE DAEMON'S REFUSAL, TYPED:
    # an envelope `{error: {code, message}}` reaches a surface as its
    # SENTENCE — the message, unchanged, so every printed line and every
    # pin stands — and as the refusal's `code` word and HTTP `status`
    # beside it, so a surface that must tell a 409 `runner_elsewhere` from
    # a 422 `mcp_unavailable` reads the code, never the sentence (`refuse`
    # relayed the message alone, and the ACP surface's error mapping was
    # sentence patterns a daemon rewording would break silently). `code`
    # is nil for an envelope-less refusal (the fallback sentence).
    class Refused < Rho::Error
      attr_reader :code, :status

      def initialize(message, code:, status:)
        super(message)
        @code = code
        @status = status
      end
    end

    # Stated by the caller: reaching the socket is local, what the handler
    # does behind it ranges from a memory read to a Nexus ceremony, and
    # Net::HTTP's defaults are a silent two-minute wait against a slow daemon.
    Budget = Data.define(:open, :read) do
      # A relayed request's wait: the step's own clock, the
      # sweep's minute that settles an unclaimed row past it, then the
      # kernel round-trips behind them. `rho relay`, `rewind`, `regenerate`.
      def self.for_relay(timeout_ms)
        new(open: Rho::Core::LOCAL_OPEN_TIMEOUT,
          read: (timeout_ms / 1000.0).ceil + Rho::Core::SWEEP_SECONDS + Rho::Core::Budget::KERNEL_ROUND_TRIP.read)
      end
    end

    LOCAL_OPEN_TIMEOUT = 2
    LOCAL_RESPONSE_SLACK = 30
    # The sweep that settles an unclaimed relayed row.
    SWEEP_SECONDS = 60
    # A memory read: /healthz, /status, this daemon's own tables.
    Budget::LOCAL = Budget.new(open: LOCAL_OPEN_TIMEOUT, read: 15)
    # Two kernel round-trips behind a loopback URL, neither waiting on a
    # model: create-then-start, one settle, the loop then its deliverable.
    Budget::KERNEL_ROUND_TRIP = Budget.new(
      open: LOCAL_OPEN_TIMEOUT,
      read: (2 * CybrosAgent::Api::BaseClient::DEFAULT_REQUEST_TIMEOUT) + LOCAL_RESPONSE_SLACK
    )
    # Start may verify, retry proactive freshness, read two planes and ask
    # for a new authorization; cancel makes one arbitration request.
    Budget::DEVICE_START = Budget.new(
      open: LOCAL_OPEN_TIMEOUT,
      read: (3 * CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT) +
        (2 * CybrosAgent::Api::BaseClient::DEFAULT_REQUEST_TIMEOUT) +
        Daemon::Ceremony::ACTIONABLE_WAIT +
        LOCAL_RESPONSE_SLACK
    )
    Budget::DEVICE_CANCEL = Budget.new(
      open: LOCAL_OPEN_TIMEOUT,
      read: CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT + LOCAL_RESPONSE_SLACK
    )
    # Moving the tools drains the runner and rebuilds it, which waits on
    # handlers that were asked to stop.
    Budget::ENVIRONMENT = Budget.new(open: LOCAL_OPEN_TIMEOUT, read: Budget::LOCAL.read + LOCAL_RESPONSE_SLACK)

    # The row a model resolves to, from the files alone (`adaptation_choice`).
    Resolution = Data.define(:subject, :resolver, :choice)

    # `home` is public for the one extension verb that writes the person's
    # own settings file from this process (`rho runners use`).
    attr_reader :home

    # `config` is the settings the daemon-less verbs read (the mode of a
    # `rho connect`/`rho disconnect` with no daemon running); a running
    # daemon answers its own. No `out`: the core prints nothing.
    def initialize(home:, display_name: nil, config: nil)
      @home = home
      @display_name = display_name || Rho.default_display_name
      @config = config
    end

    def config = @config ||= Config.load(@home.settings_path)

    # ---- the wire shapers ----

    # THE TWO FLAGS ARE THE KERNEL'S TWO FIELDS: `--in` passes the duration through
    # as `deliver_in` — rho parses no grammar of its own, the kernel is the
    # one parser; `--at` passes an ISO 8601 time WITH an offset through as
    # given, and resolves a NAIVE one in this terminal's own zone (the one
    # zone this process knows) before the call, sent in UTC — the recorded
    # departure: the wire refuses the ambiguity, the CLI resolves what it
    # knows. Both at once is the kernel's own word, refused here. Shared
    # by `say` and Ops's `inputs edit`.
    OFFSET_SHAPE = /(?:Z|[+-]\d\d:?\d\d)\z/i

    def self.schedule_fields(deliver_at: nil, deliver_in: nil)
      raise Rho::Error, "deliver_at_ambiguous: name --at or --in, not both" if deliver_at && deliver_in
      return { "deliver_in" => deliver_in.to_s } if deliver_in
      return {} if deliver_at.nil?

      { "deliver_at" => deliver_at_wire(deliver_at.to_s) }
    end

    def self.deliver_at_wire(value)
      return value if OFFSET_SHAPE.match?(value)

      Time.iso8601(value).utc.iso8601
    rescue ArgumentError
      raise Rho::Error, "deliver_at_invalid: --at takes an ISO 8601 time (2026-09-16T09:00:00Z, " \
        "or 2026-09-16T09:00:00 in this terminal's zone)"
    end

    # ---- the client ----

    # Liveness is proven by connecting, never by a pid: the announcement may
    # describe a daemon that died without unwinding. The proof is kept for
    # `require_daemon`: one core is one verb's worth of calls, and a surface
    # that outlives a daemon builds a new core.
    def running_daemon
      document = Rho::StateFile.new(@home.announcement_path).read
      return nil unless document.is_a?(Hash) && document["endpoint"]

      response =
        begin
          get(document, "/healthz")
        rescue ConnectionError
          return nil
        end
      return nil unless response.code == "200"

      health = parse(response)
      unless document["version"] == Daemon::ANNOUNCEMENT_VERSION &&
          health["status"] == "ok" &&
          health["version"].is_a?(String) &&
          health["control_version"] == Daemon::ANNOUNCEMENT_VERSION
        raise ConnectionError, "the live local daemon does not report a valid health document"
      end

      @daemon = document
    end

    def require_daemon
      @daemon || running_daemon ||
        raise(Rho::Error, "no local daemon is running; start one with `rho server`")
    end

    def get(daemon, path, budget: Budget::LOCAL)
      send_request(daemon, Net::HTTP::Get, path, budget: budget)
    end

    def post(daemon, path, body = nil, budget:)
      send_request(daemon, Net::HTTP::Post, path, budget: budget, body: body)
    end

    # A whole replacement on the daemon's surface (the access carrier's
    # route), never a partial write.
    def put(daemon, path, body = nil, budget:)
      send_request(daemon, Net::HTTP::Put, path, budget: budget, body: body)
    end

    def patch(daemon, path, body = nil, budget:)
      send_request(daemon, Net::HTTP::Patch, path, budget: budget, body: body)
    end

    # Every route the core calls answers JSON; anything else (the webui's SPA
    # fallback on an unrouted GET, say) is a daemon that is not the one we
    # think it is, and must be one sentence rather than a parser backtrace.
    def parse(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise ConnectionError, "the local daemon answered with something that is not JSON"
    end

    # The daemon reports a failure two ways: an error envelope for a request
    # it refused, and a connection document whose phase is `error` for a
    # ceremony that failed. Both are strings to a human.
    def failure_message(document)
      error = document["error"]
      (error.is_a?(Hash) ? error["message"] : error).to_s
    end

    # ---- the ceremony ----

    # ONE `POST /device/start`: the document as the daemon answered it — a
    # `connection_bootstrapping` envelope included, which the surface
    # decides to wait out (`Rho::Cli::Connect`).
    def start_ceremony(daemon)
      parse(post(daemon, "/device/start", budget: Budget::DEVICE_START))
    end

    # ONE `GET /status`. Anything but 200 is a daemon that is no longer the
    # one `running_daemon` proved live a moment ago: a restarted daemon
    # mints a new bearer, and a poll on it would answer 401 forever.
    def status_document(daemon)
      response = get(daemon, "/status")
      unless response.code.to_i == 200
        raise ConnectionError, "the local daemon stopped answering (HTTP #{response.code})"
      end

      parse(response)
    end

    # THE PAIR OF CONNECT: revoke this machine's credentials on
    # Nexus and forget them — the runner half alone with `runner: true`.
    # Through the daemon when one runs (it refuses while work is in flight),
    # else in-process from the vault under the same boot lock. Answers the
    # daemon's document, or the same shape built from the in-process result.
    def disconnect(runner: false)
      daemon = running_daemon
      daemon ? disconnect_through(daemon, runner: runner) : disconnect_in_process(runner: runner)
    end

    # The ceremony with no daemon: the identical flow in-process under the
    # boot lock, the mode's idle shape from the settings the daemon would
    # read. Yields the code document once when a ceremony starts (a resumed
    # connection yields nothing); answers the identity.
    def connect_in_process
      lock = Lock.acquire(@home.boot_lock_path)
      connection = Connection.new(
        home: @home.prepare,
        device_flow: CybrosAgent::DeviceFlow::Client.new(base_url: @home.base_url),
        display_name: @display_name, mode: config.mode
      )
      return connection.identity if connection.resume

      connection.start
      yield connection.to_h if block_given?
      connection.await
      connection.identity
    ensure
      lock&.release
    end

    # ---- the stored facts (no daemon needed) ----

    # The connection pointer as the disk holds it, nil when this home was
    # never connected. Unverified: `stored_identity` is the verification.
    def stored_connection = Rho::StateFile.new(@home.connection_pointer_path).read

    # The pointer verified as this home's own (`StoredConnectionError` when
    # it belongs elsewhere or is incomplete), as an `Identity`.
    def stored_identity(pointer) = Identity.from_pointer(home: @home, pointer: pointer).verify_belongs_here

    # With no daemon the row is still a durable answer: the files alone
    # (the gem's rows, the home's local rows, the settings' knob) for the
    # default model; a runner-mode home declares none; a pack the files
    # refuse answers its sentence rather than a row.
    def stored_facts
      return nil if config.mode == "runner"

      Rho::Adaptations.load(config, home: @home).facts
    rescue ConfigurationError => error
      { "row" => "unreadable", "source" => error.message }
    end

    # ---- the facts ----

    # `rho providers` (the provider admission floor): the
    # account's lanes through the daemon — a kernel fact behind its own
    # route.
    def providers
      response = get(require_daemon, "/providers", budget: Budget::KERNEL_ROUND_TRIP)
      document = parse(response)
      refuse(response, document, "the daemon refused to read the provider lanes") unless response.code.to_i == 200

      Array(document["providers"])
    end

    # The account's currently available models, including capabilities and pricing.
    def models(workload: nil)
      return models_in_process(workload: workload) unless running_daemon

      query = URI.encode_www_form({ workload: workload }.compact)
      path = query.empty? ? "/models" : "/models?#{query}"
      response = get(require_daemon, path, budget: Budget::KERNEL_ROUND_TRIP)
      document = parse(response)
      refuse(response, document, "the daemon refused to read the models") unless response.code.to_i == 200

      document.fetch("models")
    end

    # THE KERNEL'S FACTS for a model, off `GET /adaptations` through the daemon:
    # `known`, `tool_calls`. Refused as the daemon's sentence.
    def model_facts(model)
      response = get(require_daemon, "/adaptations?model=#{URI.encode_www_form_component(model)}")
      document = parse(response)
      refuse(response, document, "the daemon refused to read the model's facts") unless response.code.to_i == 200

      document.fetch("facts")
    end

    # `rho adaptations [--model M]`: the row M (else
    # `default_model`) resolves to, from the FILES alone — the gem's rows,
    # the home's local rows under `adaptations_dir`, the settings' knob —
    # with the resolver, so a surface can print the boot row beside it. No
    # storage, no kernel fetch: what the daemon would boot under. A model
    # without its lane segment is refused in the daemon's own sentence;
    # none at all is the default row.
    def adaptation_choice(model: nil)
      subject = model || config.default_model
      raise Rho::Error, "model is required, as provider/reference" unless subject.nil? || subject.include?("/")

      resolver = Rho::Adaptations.load(config, home: @home)
      Resolution.new(subject: subject, resolver: resolver, choice: resolver.for(subject))
    end

    # ---- where the tools are pointed ----

    # WHERE THIS MACHINE'S TOOLS ARE POINTED: the
    # `environment` document — the root, its source, the branch — off the
    # Environment extension's `GET /environment`, a memory read. `rho env`
    # prints it; the ACP surface binds a session's cwd against it.
    def environment
      response = get(require_daemon, "/environment")
      document = parse(response)
      refuse(response, document, "the daemon refused to read the environment") unless response.code.to_i == 200

      document.fetch("environment")
    end

    # POINT THE TOOLS at `root` (nil clears back to the settings file) over
    # `POST /environment`: the daemon refuses a path that is no directory
    # (`not_a_directory`), relayed as its sentence, and never work in
    # flight (a running call keeps the env it was built on); the move rebuilds placement zero — its env,
    # toolset and store — and announces the root again, hence its own
    # budget. Answers the `environment` document as it stands after the move.
    def repoint_environment(root)
      response = post(require_daemon, "/environment", { "root" => root }, budget: Budget::ENVIRONMENT)
      document = parse(response)
      refuse(response, document, "the daemon refused to move the tools") unless response.code.to_i == 200

      document.fetch("environment")
    end

    private

      # With no daemon the boot lock protects the same refresh-and-persist
      # credential owner used by connect. Never load a second refresh owner
      # beside a live daemon.
      def models_in_process(workload:)
        lock = Lock.acquire(@home.boot_lock_path)
        pointer = stored_connection
        raise Rho::Error, "This home is not connected; run rho connect first." if pointer.nil?

        identity = stored_identity(pointer)
        raise Rho::Error, "Model discovery needs full or agent mode." if identity.runner_mode?

        authority = CybrosAgent::DeviceFlow::Client.new(base_url: @home.base_url)
        credential = CybrosAgent::Credentials::OAuth.load(authority: authority, store: identity.vault)
        raise Rho::Error, "Stored credentials are missing; run rho connect again." if credential.nil?

        client = CybrosAgent::Client.new(base_url: @home.base_url, credential_provider: credential.method(:member_credential).to_proc)
        client.models.list(workload: workload).map do |row|
          row.to_h.transform_keys(&:to_s).merge("pricing" => row.pricing.to_h.transform_keys(&:to_s))
        end
      ensure
        lock&.release
      end

      # ONE REFUSAL SHAPE: the daemon's sentence (else the fallback) as the
      # message, its code word and the response's status beside it.
      def refuse(response, document, fallback)
        error = document["error"]
        error = { "message" => error } unless error.is_a?(Hash)
        raise Refused.new(error["message"] || fallback, code: error["code"], status: response.code.to_i)
      end

      def disconnect_through(daemon, runner:)
        response = post(daemon, "/disconnect", { "runner" => runner }, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document if response.code.to_i == 200

        refuse(response, document, "the daemon refused to disconnect")
      end

      # No daemon: the vaults under the boot lock, every stored lineage.
      def disconnect_in_process(runner:)
        lock = Lock.acquire(@home.boot_lock_path)
        pointer = stored_connection
        raise Rho::Error, "this home is not connected" if pointer.nil?

        identity = stored_identity(pointer)
        device_flow = CybrosAgent::DeviceFlow::Client.new(base_url: @home.base_url)
        credentials = Rho::Credentials.new(
          agent: (CybrosAgent::Credentials::OAuth.load(authority: device_flow, store: identity.vault) unless identity.runner_mode?),
          runner: (CybrosAgent::Credentials::OAuth.load(authority: device_flow, store: identity.runner_vault) if identity.runner_executor_public_id)
        )
        if runner && (!credentials.runner? || identity.runner_mode?)
          raise Rho::Error, identity.runner_mode? ? "this home runs in mode runner: the runner IS the whole connection — `rho disconnect` without --runner" : "this home has no runner credential to revoke"
        end

        result = Rho::Disconnect.call(home: @home, identity: identity, credentials: credentials, runner_only: runner,
          executor_client: ->(credential) { CybrosAgent::ExecutorClient.new(base_url: @home.base_url, credential: credential) })
        { "revoked" => result.revoked, "unclaimed" => result.unclaimed, "mode" => result.mode,
          "runner_executor_public_id" => result.runner_executor_public_id,
          "identity" => Rho::Daemon::Lineage::Status.identity_facts(result.identity).transform_keys(&:to_s) }
      ensure
        lock&.release
      end

      # The failures are local ones — a daemon dead mid-answer, a socket gone —
      # and none is `Rho::Error` or `CybrosAgent::Error`, so without this they
      # escaped `exe/rho`'s rescue as a backtrace.
      def send_request(daemon, klass, path, budget:, body: nil)
        uri = URI.join(daemon.fetch("endpoint"), path)
        message = klass.new(uri)
        message["Authorization"] = "Bearer #{daemon["bearer"]}" if daemon["bearer"]
        unless body.nil?
          message["Content-Type"] = "application/json"
          message.body = JSON.generate(body)
        end
        Net::HTTP.start(
          uri.host, uri.port,
          open_timeout: budget.open, read_timeout: budget.read, max_retries: 0
        ) { |http| http.request(message) }
      rescue Net::ReadTimeout => error
        # Deliberately not "cannot reach": the socket opened, so the daemon is
        # there — and telling a person to restart one that is mid-ceremony
        # destroys the ceremony, since a pending connection lives in memory.
        raise ConnectionError, "the local daemon did not answer in time (#{error.class})"
      rescue Net::OpenTimeout, IOError, SystemCallError, EOFError => error
        raise ConnectionError, "cannot reach the local daemon (#{error.class})"
      end
  end
end
