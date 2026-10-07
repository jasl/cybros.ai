require "cybros_agent"
require "time"

module Rho
  # One connection ceremony, from the code a human types to a credential
  # installed in its destination root.
  # The connection phases are: idle → starting → pending → activating → active, with error
  # as the retryable arm. They exist because a human is watching: `starting` means the
  # code has been asked for and has not arrived, `pending` means it is on screen and the
  # poll is running, and `activating` is the one window where credentials exist but the
  # daemon is not yet connected. The runner-only shape spells its pending phase
  # `pending_runner`: the same code on screen, for a grant that adds a runner beside a
  # live agent.
  #
  # ONE CONNECTION, THREE REQUEST SHAPES, decided by the
  # daemon's Ceremony from the mode and the planes it still holds:
  #   :combined — full mode from idle (or both planes lost): ONE grant
  #     carrying the agent triple AND the runner pair; the poll answers
  #     three access tokens on two lineages (`Rho::Credentials`).
  #   :agent — agent mode, or a full-mode restore whose runner plane is
  #     LIVE: branch A alone. A restore NEVER fences a live runner plane —
  #     a combined re-consume would `re_pair` the runner row and fence the
  #     credential the daemon's runner run is claiming with — so the
  #     `existing` runner OAuth is kept by object identity and never
  #     re-consumed.
  #   :runner — runner mode from idle (identifier `rho-runner`, its own
  #     root), or full mode with the agent planes live and the runner plane
  #     absent/lost (identifier `rho`): branch B, the agent half untouched;
  #     the daemon attaches the minted runner OAuth under its monitor.
  #
  # Two rules shape everything here:
  #
  #   Nothing durable is keyed until the identity is known. The token response
  #   carries no identity, so the minted bundle waits in a home-scoped
  #   staging slot until a bootstrap read says whose it is. Staging is never an
  #   active credential source — nothing composes planes from it and no
  #   rotation runs against it.
  #
  #   A retry never re-runs a ceremony it already won. If activation fails
  #   after the mint — identity resolution refused, a lock held, a vault that
  #   would not write — the staged bundle is still there, and retrying resumes
  #   at `activating`. Running the browser ceremony again would burn a second
  #   authorization and re-pair the address at a new
  #   epoch — fencing the staged bundle we are still holding.
  class Connection
    STAGING_VERSION = 4
    REQUESTS = %i[combined agent runner login].freeze
    PENDING_PHASES = %i[pending pending_runner].freeze

    attr_reader :phase, :identity, :oauth, :runner_oauth, :authority_report, :user_code,
      :verification_uri, :verification_uri_complete, :error_message, :request, :mode

    # `request` defaults to the mode's idle shape; `existing` is the
    # adopted `Rho::Credentials` a restore keeps (and `existing_identity`
    # the identity it holds), nil from idle.
    def initialize(home:, device_flow:, mode:, api_transport: nil, clock: -> { Time.now },
      on_phase: nil, display_name: nil, request: nil, existing: nil, existing_identity: nil)
      @home = home
      @device_flow = device_flow
      @mode = Config::MODES.include?(mode) ? mode : raise(ArgumentError, "unknown mode #{mode.inspect}")
      @request = request || self.class.idle_request(mode)
      raise ArgumentError, "unknown request shape #{@request.inspect}" unless REQUESTS.include?(@request)

      @existing = existing
      @existing_identity = existing_identity
      @api_transport = api_transport
      @clock = clock
      @on_phase = on_phase
      @display_name = display_name || Rho.default_display_name
      @phase = :idle
      @reservation_lock = Mutex.new
      @won = false
      @staging = Rho::StateFile.new(home.pending_connection_path)
    end

    # The shape a mode pairs from idle.
    def self.idle_request(mode)
      case mode
      when "runner" then :runner
      when "agent" then :agent
      else :combined
      end
    end

    def self.recovery_request(mode, lost)
      return :runner if mode == "runner"

      agent_lost = (lost - [:runner_transport]).any?
      runner_lost = lost.include?(:runner_transport)
      if agent_lost && runner_lost then :combined
      elsif runner_lost then :runner
      else :agent
      end
    end

    # The branch a staged bundle was minted on, or nil without one — read
    # before the boot-time resume decides what stands behind it.
    def self.staged_branch(home)
      document = Rho::StateFile.new(home.pending_connection_path).read
      document && document["branch"]
    rescue StateError
      nil
    end

    # Ask for a code. Deliberately does not poll: the caller displays what this
    # returns and drives #await separately, so a browser client is never left
    # holding a request open for fifteen minutes.
    def start
      transition(:starting)
      @authorization = request_authorization
      @user_code = @authorization.user_code
      @verification_uri = @authorization.verification_uri
      @verification_uri_complete = @authorization.verification_uri_complete
      transition(pending_phase)
      self
    rescue CybrosAgent::DeviceFlow::Error, CybrosAgent::TransportError => error
      fail_with(error)
    end

    # Poll to the end of the ceremony, then activate. Both halves are here
    # because the staged bundle in between belongs to neither: it is not a
    # connection yet and cannot be left lying around as if it were.
    def await
      raise ConnectionError, "no connection is pending" unless PENDING_PHASES.include?(@phase)

      # Kills abandon waits, never commits. An orderly cancel may kill this
      # poll only after Nexus's row-lock winner proves Consume did not happen;
      # once the kernel has minted a bundle, a kill landing before it is staged
      # orphans a refresh-token lineage nobody will ever present.
      # The bundle EXISTS from inside the poll's own return path, so the mask
      # covers poll-and-stage both and re-opens delivery only at blocking
      # waits — a mask that started after the poll returned left the
      # returning frame exposed. Staged, a kill anywhere later is already
      # covered: activation resumes from the staging slot on the next attempt
      # or the next boot.
      Thread.handle_interrupt(Object => :never) do
        credentials = Thread.handle_interrupt(Object => :on_blocking) do
          @device_flow.await_credentials(@authorization)
        end
        if credentials in CybrosAgent::ApplicationOAuth::Credentials
          # Runtime staging comes first: a failed Human-session write must
          # not discard a won Agent/Runner pairing and force another epoch.
          stage(ApplicationConnection.runtime_credentials(credentials)) unless @request == :login
          @won = true
          @device_flow.accept_human(credentials)
        elsif @request != :login
          stage(credentials)
        end
        if @request == :login
          @identity = @existing_identity
          @oauth = @existing
          @won = true
          transition(:active)
          return self
        end
        @won = true
        # The local cancel/shutdown boundary can now distinguish a mere poll
        # from a Consume result that is already durable. Keep the transition in
        # the same interrupt mask as staging: there must be no observable
        # `pending` window after the bundle exists.
        transition(:activating)
      end
      activate
    rescue StateFile::PublishedError => error
      # PublishedError means pending.json is readable even though its directory
      # fsync was unconfirmed. The ceremony is won and must be resumed, never
      # mistaken for a cancelable pre-Consume error.
      @won = true
      fail_with(error)
    rescue CybrosAgent::Error, Rho::Error => error
      raise if @phase == :error

      fail_with(error)
    end

    # Resume from whatever survived. A staged bundle short-circuits straight to
    # activation; anything else needs a ceremony.
    def resume
      staged = staged_credentials
      return false if staged.nil?

      @credentials = staged
      @won = true
      activate
      true
    end

    # Code and Device login share this persist-before-use installation path.
    # The browser's Human credential is owned elsewhere and never enters it.
    def receive(credentials)
      stage(credentials)
      @won = true
      activate
    end

    # Daemon-only ownership primitive. The daemon publishes the Connection and
    # reserves it under its tiny ceremony mutex before doing any file or
    # network IO, so another start joins `starting` rather than repeating the
    # idle staging decision. Direct callers keep using #start/#resume.
    def reserve(notify: true)
      reserved = @reservation_lock.synchronize do
        return false unless @phase == :idle

        @phase = :starting
        true
      end
      @on_phase&.call(:starting) if reserved && notify
      reserved
    end

    # Continue a daemon-reserved Connection. A staged bundle wins over a new
    # authorization; otherwise only the slow authorization request runs here.
    # Publishing `pending` is a separate step so the daemon can install the
    # poller in the same state boundary.
    def continue_reserved
      raise ConnectionError, "the connection is not reserved" unless @phase == :starting

      staged = staged_credentials
      if staged
        @credentials = staged
        @won = true
        activate
        :resumed
      else
        prepare_authorization
        :started
      end
    rescue CybrosAgent::Error, Rho::Error => error
      raise if @phase == :error

      fail_with(error)
    end

    def publish_pending(notify: true)
      unless @phase == :starting && @authorization
        raise ConnectionError, "the connection has no authorization to publish"
      end

      @phase = pending_phase
      @on_phase&.call(@phase) if notify
      self
    end

    # Nexus arbitrates cancel versus Consume on the DeviceAuthorization row.
    # Local phase is deliberately not the oracle: Consume may have committed
    # while its token response is still on the wire. A durable staged bundle
    # already proves Consume won; otherwise ask Nexus about the exact private
    # Authorization. With neither, cancellation is local only when no staged
    # commit exists.
    def cancellation_outcome
      return :consumed if @won
      return @device_flow.cancel_authorization(@authorization) if @authorization
      return :canceled if @staging.read.nil?

      raise StoredConnectionError,
        "a staged Agent connection exists without a cancelable authorization"
    end

    # THE RUNNER-ONLY SHAPE ON A LIVE AGENT installs by attaching, under the
    # daemon's monitor, never by replacing the lineage: the daemon reads
    # `runner_oauth` and `identity` and adopts through `adopt_runner`.
    def adopts_runner? = @request == :runner && @mode == "full"

    def to_h
      document = { "phase" => @phase.to_s, "branch" => @request.to_s, "mode" => @mode }
      if PENDING_PHASES.include?(@phase)
        document["user_code"] = @user_code
        document["verification_uri"] = @verification_uri
        document["verification_uri_complete"] = @verification_uri_complete
      end
      document["error"] = @error_message if @phase == :error
      document["identity"] = identity_facts if @identity
      document
    end

    def inspect = "#<Rho::Connection phase=#{@phase} branch=#{@request}>"
    alias_method :to_s, :inspect

    private

      def pending_phase = @request == :runner ? :pending_runner : :pending

      def prepare_authorization
        @authorization = request_authorization
        @user_code = @authorization.user_code
        @verification_uri = @authorization.verification_uri
        @verification_uri_complete = @authorization.verification_uri_complete
      end

      # The wire request per shape: the combined grant names
      # both identities on one row; branch B names the runner identifier the
      # MODE presents — `rho` for the in-process runner, `rho-runner` for
      # runner mode — so a full rho and a runner-mode rho under one manager
      # hold two live rows. THE ONE PAIRING SITE: every
      # identifier is the program's constant plus this home's instance
      # part — `rho.3f9a2c1e` — so several installs of one program pair
      # under one steward as separate rows, and a reconnect of the SAME
      # home presents the same identifier and re-pairs the same Profile.
      def request_authorization
        case @request
        when :login
          if @mode == "runner"
            @device_flow.request_runner_authorization(registration_identifier: registration_identifier,
              runner_display_name: @display_name, connection_mode: "login")
          else
            @device_flow.request_authorization(agent_identifier: agent_identifier,
              agent_display_name: @display_name, executor_display_name: @display_name,
              runner: (@mode == "full" ? { identifier: registration_identifier, display_name: @display_name } : nil),
              connection_mode: "login")
          end
        when :combined
          @device_flow.request_authorization(
            agent_identifier: agent_identifier, agent_display_name: @display_name,
            executor_display_name: @display_name,
            runner: { identifier: registration_identifier, display_name: @display_name }
          )
        when :agent
          @device_flow.request_authorization(
            agent_identifier: agent_identifier, agent_display_name: @display_name,
            executor_display_name: @display_name
          )
        else
          @device_flow.request_runner_authorization(
            registration_identifier: registration_identifier, runner_display_name: @display_name
          )
        end
      end

      def agent_identifier = "#{Rho::AGENT_IDENTIFIER}.#{instance_id}"

      def registration_identifier
        "#{@mode == "runner" ? Rho::STANDALONE_REGISTRATION_IDENTIFIER : Rho::REGISTRATION_IDENTIFIER}.#{instance_id}"
      end

      # The home's, derived at `prepare` — a Connection is always built on
      # a prepared home, so a missing id is a caller's fault said by path.
      def instance_id
        @home.instance_id or raise StateError, "#{@home.instance_path} is absent: the home was not prepared"
      end

      # Durable before anything reads it: a crash between the mint and the
      # install must leave the bundle recoverable, or the human repeats the
      # ceremony for credentials that already exist on the kernel's side.
      # The branch rides with it, so a resume files the shape that was won.
      def stage(credentials)
        @credentials = credentials
        document = {
          "version" => STAGING_VERSION,
          "base_url" => @home.base_url,
          "branch" => @request.to_s,
          "access_token" => credentials.access_token,
          "executor_access_token" => credentials.executor_access_token,
          "refresh_token" => credentials.refresh_token,
          "token_type" => credentials.token_type,
          "expires_in" => credentials.expires_in,
          "staged_at" => @clock.call.utc.iso8601,
        }
        if credentials.runner_plane?
          document["runner"] = {
            "access_token" => credentials.runner_access_token,
            "refresh_token" => credentials.runner_refresh_token,
          }
        end
        @staging.write(document)
        credentials
      end

      def staged_credentials
        document = @staging.read
        return nil if document.nil?

        unless document["version"] == STAGING_VERSION
          raise StoredConnectionError,
            "the staged connection is not format version #{STAGING_VERSION}"
        end
        unless document["base_url"] == @home.base_url
          raise StoredConnectionError, "the staged connection belongs to a different Nexus"
        end
        @request = document.fetch("branch").to_sym
        raise StoredConnectionError, "the staged connection names an unknown branch" unless REQUESTS.include?(@request)

        runner = document["runner"] || {}
        CybrosAgent::DeviceFlow::Credentials.new(
          access_token: document["access_token"],
          executor_access_token: document["executor_access_token"],
          refresh_token: document.fetch("refresh_token"),
          token_type: document.fetch("token_type"),
          expires_in: document.fetch("expires_in"),
          runner_access_token: runner["access_token"],
          runner_refresh_token: runner["refresh_token"]
        )
      rescue KeyError
        raise StoredConnectionError, "the staged connection is incomplete"
      end

      def activate
        transition(:activating) unless @phase == :activating
        @identity = resolve_identity
        @identity.prepare.verify_installable
        install
        transition(:active)
        self
      rescue CybrosAgent::Api::Unauthorized => error
        # The one failure that SPENDS the bundle: its whole job was to be
        # accepted by the bootstrap read, and a 401 — undifferentiated by
        # design but never transient — means no retry can make
        # it file. Keeping it staged is what wedged reconnects forever: a
        # stale bundle left by a crash between the pointer write and the
        # staging delete was resumed, refused, and kept, on every later
        # click. Deleted, the next attempt runs a real ceremony instead.
        @staging.delete
        fail_with(error)
      rescue CybrosAgent::Api::Error, CybrosAgent::Error, Rho::Error => error
        # Every other failure keeps the bundle staged. This connection was
        # won and may still work; only the filing failed — a crashed write,
        # an unreachable Nexus — and a retry resumes here rather than asking
        # the human again.
        fail_with(error)
      end

      # The bootstrap reads per shape: `/executor` for where the agent is,
      # `/profile` for who it is (the member plane carries no address — see
      # Identity), and the runner credential's own `/executor`, which must
      # answer a runner-kind row.
      def resolve_identity
        planes = CybrosAgent.planes_for(@credentials, base_url: @home.base_url, transport: @api_transport)
        case @request
        when :combined
          address = require_plane(planes.executor_client, "executor_transport").executor.executor
          runner = runner_address(require_plane(planes.runner_client, "runner_transport"))
          profile = require_plane(planes.client, "member").profile.fetch
          @authority_report = live_report(%i[member executor_transport runner_transport], profile: profile)
          Identity.agent(
            home: @home, user_public_id: profile.member.public_id, executor_public_id: address.public_id,
            mode: @mode, runner_executor_public_id: runner.public_id
          )
        when :agent
          address = require_plane(planes.executor_client, "executor_transport").executor.executor
          profile = require_plane(planes.client, "member").profile.fetch
          @authority_report = live_report(%i[member executor_transport], profile: profile)
          kept_runner = @existing&.runner && @existing_identity&.runner_executor_public_id
          @authority_report[:planes][:runner_transport] = kept_runner_plane if kept_runner
          Identity.agent(
            home: @home, user_public_id: profile.member.public_id, executor_public_id: address.public_id,
            mode: @mode, runner_executor_public_id: kept_runner
          )
        else
          runner = runner_address(require_plane(planes.executor_client, "runner_transport"))
          @authority_report = live_report(%i[runner_transport])
          if @mode == "runner"
            Identity.runner(home: @home, executor_public_id: runner.public_id)
          else
            require_existing_identity.with_runner(runner.public_id)
          end
        end
      end

      # The ceremony's own report: every plane it just read is live, and
      # the member handle it read rides beside them so
      # `rho status` names it before the first probe.
      def live_report(planes, profile: nil)
        { planes: planes.to_h { |plane| [plane, :live] }, lost: false,
          member_handle: profile&.member&.handle }.compact
      end

      # The runner plane a restore keeps is asked, not assumed: one read on
      # its own credential, reported the way the authority probe reports.
      def kept_runner_plane
        CybrosAgent::ExecutorClient.new(
          base_url: @home.base_url, credential: @existing.runner_credential, transport: @api_transport
        ).executor
        :live
      rescue CybrosAgent::Api::Unauthorized, CybrosAgent::Credentials::PlaneUnavailable
        :unauthorized
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError, CybrosAgent::Error
        :unknown
      end

      def runner_address(client)
        address = client.executor.executor
        return address if address.kind == "runner"

        raise ConnectionError, "the runner grant named a #{address.kind}, not a runner"
      end

      def require_existing_identity
        @existing_identity ||
          raise(ConnectionError, "a runner grant on a full-mode daemon needs the live agent connection to attach to")
      end

      # A ceremony that produced no credential for a required bootstrap read
      # cannot be filed anywhere. Fresh consumes do not do this, but a
      # bundle whose member authority died before it was ever installed would.
      def require_plane(client, plane)
        return client unless client.nil?

        raise ConnectionError, "this connection produced no #{plane} credential to identify itself with"
      end

      # Install, record, then drop staging — in that order, so a crash leaves
      # the bundle recoverable at every point rather than lost between two
      # files. The runner lineage always lands in `runner_credentials.json`.
      def install
        @oauth =
          case @request
          when :combined
            Rho::Credentials.new(agent: issue(@credentials, @identity.vault),
              runner: issue(@credentials.runner_half, @identity.runner_vault))
          when :agent
            # THE PIN: the restore keeps the live runner OAuth object and
            # never re-consumes it.
            Rho::Credentials.new(agent: issue(@credentials, @identity.vault), runner: @existing&.runner)
          else
            @runner_oauth = issue(@credentials, @identity.runner_vault)
            @mode == "runner" ? Rho::Credentials.new(runner: @runner_oauth) : @existing
          end
        @identity.record(clock: @clock)
        Rho::StateFile.new(@home.connection_pointer_path).write(@identity.pointer_document)
        @staging.delete
      end

      def issue(credentials, store)
        CybrosAgent::Credentials::OAuth.issue(
          credentials: credentials, authority: @device_flow, store: store, clock: @clock
        )
      end

      def identity_facts
        {
          "user_public_id" => @identity.user_public_id,
          "executor_public_id" => @identity.executor_public_id,
          "runner_executor_public_id" => @identity.runner_executor_public_id,
          "instance_id" => @home.instance_id,
        }.compact
      end

      def fail_with(error)
        @error_message = CybrosAgent::Redaction.call(error.message)
        transition(:error)
        raise error
      end

      def transition(phase)
        @phase = phase
        @on_phase&.call(phase)
      end
  end
end
