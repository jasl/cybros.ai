require_relative "ceremony/stop"
require_relative "ceremony/disconnect"

module Rho
  class Daemon
    # The device flow: `/device/start`,
    # `/device/cancel`, `/disconnect`, the boot-time resume, the poller
    # thread and the ceremony half of an orderly stop. No lock of its own:
    # the slot is the Lineage's.
    #
    # THE CEREMONY DECIDES THE SHAPE: from idle, the mode's
    # (full → combined, agent → A, runner → B); from `active`, from the
    # planes the daemon still holds — the agent planes lost beside a live
    # runner → A alone (a restore never fences a live runner plane); the
    # agent planes live and the runner plane absent or lost under full mode
    # → B for the in-process identifier (`pending_runner`); both lost →
    # combined.
    class Ceremony
      include Stop
      include Disconnect

      # A caller waits, bounded, for a document it can act on; past the bound
      # the bare phase is returned, and `/status` is where a ceremony is
      # followed anyway.
      ACTIONABLE_KEYS = %w[user_code identity error].freeze
      ACTIONABLE_WAIT = 5
      ACTIONABLE_POLL = 0.02
      LOST_PLANE_STATES = %i[unauthorized absent].freeze

      # The lineage edges (adopt, adopt_runner, settle, lose, lose_runner,
      # transition) are the daemon's callbacks: what they do outside the
      # monitor needs the server.
      def initialize(lineage:, home:, device_flow:, wire:, clock:, display_name:, log:, maintenance:,
        announce:, adopt:, settle:, lose:, transition:, mode: "full", adopt_runner: ->(**) { nil },
        lose_runner: ->(**) { nil })
        @lineage = lineage
        @home = home
        @device_flow = device_flow
        @wire = wire
        @clock = clock
        @display_name = display_name
        @log = log
        @maintenance = maintenance
        @announce = announce
        @adopt = adopt
        @adopt_runner = adopt_runner
        @settle = settle
        @lose = lose
        @lose_runner = lose_runner
        @transition = transition
        @mode = mode
      end

      # At most one ceremony in flight, and starting is idempotent: a second
      # device code would re-pair the address at a new epoch and fence this
      # daemon's credential — unless that credential is already lost.
      def start
        return Refusal.stopping if @lineage.stopping?
        return Refusal.bootstrapping if @lineage.bootstrapping?

        # Joining precedes the phase check: an independent Runner can keep
        # the daemon active while its Agent is restored, and `active` is
        # joinable only before adoption.
        if (connection = @lineage.joinable)
          adopt_unadopted(connection)
          return [200, actionable(connection)]
        end

        # A refusal is only right if this connection still works, and the one
        # endpoint that can say so is rotation (`invalid_grant`);
        # a terminal answer ends the connection, so the phase is re-read below.
        verify_authority if @lineage.phase == :active

        expected_credentials = Lineage::UNCHECKED
        shape = Connection.idle_request(@mode)
        if @lineage.phase == :active
          authority_state, authority_about, authority_shape = required_authority_state
          case authority_state
          when :complete
            return Refusal.new(status: 409, code: "already_connected", message: "Already connected")
          when :unknown
            return Refusal.new(status: 503, code: "authority_unknown",
              message: "Cannot verify the current Agent connection; try again when Nexus is reachable")
          when :recoverable
            # Any surviving plane remains usable while its replacement
            # converges beside it.
            expected_credentials = authority_about
            shape = authority_shape
          else
            raise StateError, "the Agent connection has an unknown authority state"
          end
        end

        # Re-checked under the lock: two callers may both have passed the
        # probe above, but only one may claim the slot.
        return Refusal.stopping if @lineage.stopping?

        claim_connection(expected_credentials, shape)
      rescue CybrosAgent::Error, Rho::Error => error
        Refusal.new(status: 502, code: "connection_failed",
          message: CybrosAgent::Redaction.call(error.message))
      end

      # Local phase cannot say whether a kill is safe: Nexus may have committed
      # Consume while the token response is on the wire, so its cancel command
      # (the same row lock as Consume) returns the winner.
      def cancel
        slot = @lineage.slot_snapshot
        connection = slot.connection
        phase = connection&.phase
        return Refusal.bootstrapping if slot.bootstrapping
        if connection.nil?
          unless Rho::StateFile.new(@home.pending_connection_path).read.nil?
            raise StoredConnectionError,
              "a staged Agent connection exists without an in-memory cancellation owner"
          end
          return [200, { canceled: true }] if slot.last_cancel_succeeded
        end

        # `starting` has nothing to cancel yet; `activating`/`active` are past
        # Consume; an error corpse with an authorization still asks Nexus. A
        # `pending_runner` cancel leaves the daemon active with no runner.
        if phase == :active ||
            (slot.phase == :active && !%i[pending pending_runner error starting activating].include?(phase))
          return Refusal.new(status: 409, code: "already_connected", message: "Already connected")
        end
        if phase == :starting || phase == :activating
          message =
            if phase == :starting
              "The ceremony is still starting; cancel it once it is pending"
            else
              "The ceremony is completing and can no longer be canceled"
            end
          return Refusal.new(status: 409, code: phase.to_s, message: message)
        end

        return [200, { canceled: true }] if connection.nil?

        case connection.cancellation_outcome
        when :canceled
          quiesce_canceled_poller(connection)
          @lineage.release_slot(connection, canceled: true)
          @announce.call
          [200, { canceled: true }]
        when :consumed
          Refusal.new(status: 409, code: "too_late",
            message: "The connection was already authorized and is being completed")
        else
          raise StateError, "Nexus returned an unknown cancellation outcome"
        end
      rescue CybrosAgent::Error, Rho::Error => error
        @log.warn("connection.cancel_unknown", error: error)
        Refusal.new(status: 503, code: "cancel_unknown",
          message: "Cannot determine whether cancellation beat connection; the ceremony is still running")
      end

      # A daemon that already has credentials comes back connected without a
      # second browser ceremony; failure leaves it up and disconnected,
      # serving the flow that can fix it.
      def resume_stored
        # Staging is the latest unfinished commit intent: replacement writes
        # vault → session → pointer → deletes staging, so any crash before
        # that last step resumes the replacement, not the older pointer —
        # except either staged half on a full-mode daemon, which keeps the
        # pointer's other lineage and needs it adopted first.
        if @mode == "full" && %w[agent runner].include?(Connection.staged_branch(@home))
          resume_pointer
          resume_staged(existing: @lineage.credentials, existing_identity: @lineage.identity)
          return
        end
        return if resume_staged
        resume_pointer
      rescue StoredConnectionError, CybrosAgent::Error, Rho::Error => error
        @lineage.record_connection_error(CybrosAgent::Redaction.call(error.message))
        @log.warn("connection.unavailable", error: error)
        @transition.call(:disconnected)
      end

      def build_connection(request: nil, existing: nil, existing_identity: nil)
        Connection.new(
          home: @home, device_flow: device_flow, mode: @mode,
          api_transport: @wire.api_transport, clock: @clock,
          display_name: @display_name, request: request, existing: existing, existing_identity: existing_identity,
          on_phase: ->(_phase) { @announce.call }
        )
      end

      private

        def device_flow
          @device_flow ||= CybrosAgent::DeviceFlow::Client.new(base_url: @home.base_url)
        end

        # A staged bundle, finished; false when there is none.
        def resume_staged(existing: nil, existing_identity: nil)
          staged = build_connection(existing: existing, existing_identity: existing_identity)
          @lineage.claim_slot(staged)
          if staged.resume
            adopt(staged)
            return true
          end
          @lineage.release_slot(staged)
          false
        end

        # The pointer's connection: the mode check, the lineages loaded from
        # their vaults, every plane probed, then adopted.
        def resume_pointer
          pointer = Rho::StateFile.new(@home.connection_pointer_path).read
          return if pointer.nil?

          identity = Identity.from_pointer(home: @home, pointer: pointer).verify_belongs_here
          verify_mode(identity.mode)
          credentials = stored_credentials(identity)

          # The pointer says where to look; only a terminal refresh-lineage
          # answer collapses the durable connection, and a live answer naming
          # another identity is refused as copied state.
          report = Authority.new(
            oauth: credentials, base_url: @home.base_url, transport: @wire.api_transport,
            expected_identity: identity, mode: @mode
          ).check
          if report[:lost] && !(@mode == "full" && credentials.runner? && !report[:runner_lost])
            @settle.call(@lineage.adopt_lost(identity: identity, credentials: credentials, report: report), :disconnected)
            return
          end
          if report[:runner_lost]
            # The runner half answered terminally: adopted without it, the
            # identity keeping the id so status can say what was lost.
            credentials.drop_runner
            @log.warn("runner.authority_lost", runner: identity.runner_executor_public_id)
          end

          @log.info("connection.resumed", mode: identity.mode,
            user: identity.user_public_id, executor: identity.executor_public_id,
            runner: identity.runner_executor_public_id)
          @adopt.call(identity: identity, credentials: credentials, authority_report: report)
          @lose.call(about: credentials, report: report) if report[:lost]
        end

        # THE SETTINGS/POINTER RULE: equal → continue; agent→full
        # is recoverable (the runner plane reads absent and `rho connect`
        # opens the runner-only shape); anything else is refused with the
        # switch sentence.
        def verify_mode(stored)
          return if stored == @mode
          return if stored == "agent" && @mode == "full"

          raise StoredConnectionError,
            "this home was paired in mode #{stored}; settings say #{@mode} — `rho disconnect`, " \
            "then `rho server --mode #{@mode}` and `rho connect`"
        end

        # The composite from the vaults: the agent lineage unless runner
        # mode, the runner lineage when the identity carries a runner.
        def stored_credentials(identity)
          agent = unless identity.runner_mode?
            CybrosAgent::Credentials::OAuth.load(authority: device_flow, store: identity.vault, clock: @clock)
          end
          runner = if identity.runner_executor_public_id
            CybrosAgent::Credentials::OAuth.load(authority: device_flow, store: identity.runner_vault, clock: @clock)
          end
          if (identity.runner_mode? && runner.nil?) || (!identity.runner_mode? && agent.nil?)
            raise StoredConnectionError, "#{identity.root} has no credentials to reconnect with"
          end

          Rho::Credentials.new(agent: agent, runner: runner)
        end

        def claim_connection(expected_credentials, shape)
          existing = expected_credentials.equal?(Lineage::UNCHECKED) ? nil : expected_credentials
          candidate = build_connection(request: shape, existing: (existing if shape != :combined),
            existing_identity: (@lineage.identity if existing && shape != :combined))
          unless candidate.reserve(notify: false)
            raise StateError, "a fresh Agent connection could not reserve the ceremony slot"
          end

          outcome = @lineage.claim_slot(candidate, expected: expected_credentials)
          case outcome
          when :claimed
            @announce.call
            continue_claimed(candidate)
          when :stopping
            Refusal.stopping
          when :already_connected
            Refusal.new(status: 409, code: "already_connected", message: "Already connected")
          when :stale
            Refusal.new(status: 503, code: "connection_changed",
              message: "The Agent connection changed while it was being checked; try again")
          else
            adopt_unadopted(outcome.connection)
            [200, actionable(outcome.connection)]
          end
        end

        def continue_claimed(connection)
          case connection.continue_reserved
          when :resumed
            adopt(connection)
          when :started
            # Until this boundary the connection remains `starting`, which
            # cancel refuses; once `pending` is visible so is its poller.
            pending = @lineage.publish_pending(connection) { poll(connection) }
            @announce.call
            return [200, pending]
          else
            raise StateError, "the Agent connection returned an unknown start outcome"
          end
          [200, actionable(connection)]
        end

        def adopt_unadopted(connection)
          return unless connection.phase == :active
          return if connection.oauth.equal?(@lineage.credentials)

          adopt(connection)
        end

        # ONE adoption door: the runner-only shape on a live agent attaches
        # its runner under the daemon's monitor; every other shape adopts
        # the connection's holder whole.
        def adopt(connection)
          if connection.adopts_runner?
            @adopt_runner.call(about: connection.oauth, identity: connection.identity, runner: connection.runner_oauth,
              authority_report: connection.authority_report)
          else
            @adopt.call(
              identity: connection.identity,
              credentials: connection.oauth,
              authority_report: connection.authority_report
            )
          end
        end

        # `[state, about, shape]`: what the daemon still holds decides which
        # shape a recovery takes (the class comment).
        def required_authority_state
          2.times do
            snapshot = @maintenance.authority_snapshot
            return [:unknown, nil, nil] if snapshot.nil?

            about = snapshot.about
            report = snapshot.report
            next unless @lineage.holds?(about)

            if report[:lost]
              next unless @lose.call(about: about, report: report)

              return [:recoverable, nil, Connection.idle_request(@mode)] unless @lineage.holds?(about)
            end

            planes = report.fetch(:planes)
            return [:unknown, about, nil] if planes.values.include?(:unknown)

            lost = planes.select { |_plane, state| LOST_PLANE_STATES.include?(state) }.keys
            lost |= [:runner_transport] if report[:runner_lost] && planes.key?(:runner_transport)
            return [:complete, about, nil] if lost.empty?

            return [:recoverable, about, recovery_shape(lost)]
          end

          [:unknown, nil, nil]
        end

        def recovery_shape(lost)
          return :runner if @mode == "runner"

          agent_lost = (lost - [:runner_transport]).any?
          runner_lost = lost.include?(:runner_transport)
          if agent_lost && runner_lost then :combined
          elsif runner_lost then :runner
          else :agent
          end
        end

        def quiesce_canceled_poller(connection)
          slot = @lineage.slot_snapshot
          thread = slot.poller if slot.connection.equal?(connection)
          return if thread.nil?

          thread.kill
          # Not `join`: inside an Async handler it would stall every local
          # request. Nexus proved Consume cannot win, so this only lets the
          # canceled wait unwind before its slot is reused.
          sleep 0.01 while thread.alive?
          @lineage.release_poller(thread)
        end

        # Monotonic, because this is a timeout rather than a fact about the
        # connection, and `@clock` may be a test's fiction.
        def actionable(connection)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ACTIONABLE_WAIT
          document = connection.to_h
          while ACTIONABLE_KEYS.none? { |key| document.key?(key) } &&
              Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            # Yields to the reactor under Async, which is what lets the fiber
            # holding the ceremony make the progress this one is waiting for.
            sleep ACTIONABLE_POLL
            document = connection.to_h
          end
          document
        end

        # This poller's own connection, never the slot's: a terminal loss can
        # nil the slot mid-await, and adopting `nil, nil` leaves a daemon at
        # `:active` holding nothing, with no way back.
        def poll(connection)
          connection.await
          adopt(connection)
        rescue StandardError
          # The connection recorded why and announced it; a failed ceremony must
          # not take the daemon down with it.
          @announce.call
        ensure
          @lineage.release_poller(Thread.current)
        end

        # Authority is asked, never inferred (every plane answers 401 alike),
        # at most once per `Lineage::VERIFY_WINDOW`, so clicking connect can
        # never spend the family write budget renewal and recovery share.
        def verify_authority
          about = @lineage.mark_verified(@clock.call)
          return if about.nil?

          @maintenance.run_once(about, verify: true)
        rescue StandardError => error
          @log.warn("authority.verify_failed", error: error)
        end
    end
  end
end
