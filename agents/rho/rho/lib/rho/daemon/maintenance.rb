require_relative "../workspaces"

module Rho
  class Daemon
    class Maintenance
      # Join, then kill: the gem holds rotate-then-persist interrupt-atomic,
      # so a kill can only ever land on a wait, never on the commit.
      RENEWAL_DRAIN_DEADLINE = 5

      # The probe's answer before the lineage commits it as an Observation.
      Probe = Data.define(:about, :report)

      def initialize(lineage:, home:, wire:, clock:, interval:, log:, announce:, lose:,
        member_credential:, on_workspace_adopted:, spawn:, workspace: nil, workspace_selection: nil,
        sweep: -> { nil })
        @lineage = lineage
        @home = home
        @wire = wire
        @clock = clock
        @interval = interval
        @log = log
        @announce = announce
        @lose = lose
        @member_credential = member_credential
        @on_workspace_adopted = on_workspace_adopted
        @spawn = spawn
        # THE ROOM KNOB: the room's public id, or nil for the
        # dedicated path.
        @workspace_selection = workspace_selection || -> { workspace }
        # Once per cycle, after Ensure-Workspace: the side sweep (rho's 24 h TTL) — the one piece of housekeeping the member plane owes.
        @sweep = sweep
        @thread = nil
      end

      # Exactly once, by `Daemon#start`.
      def start
        @thread = Thread.new { work }
      end

      def stop
        thread = @thread
        return if thread.nil?

        @lineage.stop_maintenance
        thread.join(RENEWAL_DRAIN_DEADLINE)
        thread.kill if thread.alive?
        # Thread#kill is a request; the home lock must outlive the masked
        # commit it may have interrupted, so wait until the writer is dead.
        thread.join
        @thread = nil
      end

      def running? = @lineage.maintenance_running?

      def run_once(about, verify:)
        renewal_for(about, unless_stopping: false)&.run_once(verify: verify)
      end

      # Settings use the same adoption edge immediately, without renewing
      # credentials or running the rest of the periodic maintenance cycle.
      def refresh_workspace(about)
        if about && @lineage.current?(about)
          ensure_workspace(about)
        end
      end

      def renewal_event(event, about, unless_stopping: false)
        case event
        when :lost
          # Terminal by contract (AuthorizationLostError): retire this
          # lineage's resources and allow its recovery ceremony to run.
          return @announce.call unless @lose.call(
            about: about,
            unless_stopping: unless_stopping
          )

          @log.error("renewal.lost")
        when :not_durable
          return @announce.call unless @lineage.record_not_durable(about, unless_stopping: unless_stopping)

          @log.error("renewal.not_durable")
        else
          current = unless_stopping ? @lineage.current?(about) : @lineage.holds?(about)
          return @announce.call unless current

          # A rotation is a push a live socket cannot hear: every follower's
          # pinned bearer is now stale, so it is told rather than refused.
          scheduled = rebind_runs
          @log.info("renewal.outcome", result: event, rebind_connections: scheduled)
        end
        @announce.call
      end

      # Public because the ceremony's refusal decision reads the same probe
      # the worker does; `nil` is "could not ask", not "lost".
      def authority_snapshot(about: nil)
        about ||= @lineage.credentials
        return nil unless about

        report = Authority.new(
          oauth: about, base_url: @home.base_url, transport: @wire.api_transport
        ).check
        Probe.new(about: about, report: report)
      rescue StandardError
        nil
      end

      private

        # The exit latch is `stop`'s alone; `stopping` only skips the work.
        def work
          loop do
            stopped, credentials, requested = @lineage.maintenance_wait(@interval)
            break if stopped

            begin
              # An interval wake always probes; a signaled wake (the adoption
              # wake, for Ensure-Workspace) probes only a stale observation.
              maintain_current(credentials, forced_probe: !requested)
            ensure
              @lineage.maintenance_done
            end
          end
        end

        # Everything below applies through the object-identity CAS on
        # `about`, never to a replacement lineage adopted mid-cycle.
        def maintain_current(about, forced_probe: true)
          return if about.nil?

          renewal_for(about, unless_stopping: true)&.run_once
          return unless @lineage.current?(about)

          if forced_probe || !@lineage.observation_fresh?(about)
            snapshot = authority_snapshot(about: about)
            observe(snapshot) if snapshot
          end
          return unless @lineage.current?(about)

          ensure_workspace(about)
          @sweep.call if @lineage.current?(about)
        rescue StandardError => error
          @log.warn("authority.maintenance_failed", error: error)
        end

        def renewal_for(about, unless_stopping:)
          if about&.refreshable?
            Renewal.new(oauth: about, clock: @clock,
              on_event: ->(event) { renewal_event(event, about, unless_stopping: unless_stopping) })
          end
        end

        # Outside the monitor: a rebind reaches a socket.
        def rebind_runs
          clients = @lineage.rebind_runs
          @spawn.call { clients.each(&:rebind) } unless clients.empty?
          clients.size
        end

        def observe(snapshot)
          if snapshot.report[:lost]
            @lose.call(about: snapshot.about, unless_stopping: true, report: snapshot.report)
          else
            @lineage.observe(snapshot.about, snapshot.report)
          end
        end

        # The default is adopted independently of the restored hosts. A bad
        # explicit selection never creates a replacement; existing work and
        # executor placement still recover using their original workspace.
        def ensure_workspace(about)
          credential = @member_credential.call(about)
          return if credential.nil?

          client = @wire.client(credential)
          selection = @workspace_selection.call
          workspace = selection ? Workspaces.fetch(client, selection) : adopt_dedicated(client)
          if workspace in Refusal
            @lineage.commit_workspace(about, Lineage::Workspace.error(code: workspace.code))
            @on_workspace_adopted.call(about, credential, nil)
            return
          end

          @lineage.commit_workspace(
            about, Lineage::Workspace.adopted(public_id: workspace.public_id, name: workspace.name,
              kind: workspace.dedicated ? "dedicated" : "room")
          )
          @on_workspace_adopted.call(about, credential, workspace.public_id)
        rescue CybrosAgent::TransportError
          @lineage.commit_workspace(about, Lineage::Workspace.error(code: "transport_error"))
        rescue CybrosAgent::Api::MalformedResponse
          @lineage.commit_workspace(about, Lineage::Workspace.error(code: "malformed_response"))
        rescue CybrosAgent::Api::Error => error
          @lineage.commit_workspace(about, Lineage::Workspace.error(code: error.code || "server_error"))
          @on_workspace_adopted.call(about, credential, nil) if credential
        end

        def adopt_dedicated(client)
          client.workspaces.list(dedicated_to_current_agent: true).items.first || create_dedicated_workspace(client)
        end

        def create_dedicated_workspace(client)
          name = client.profile.fetch.member.display_name
          client.workspaces.create(name: name, idempotency_key: SecureRandom.uuid).workspace
        end
    end
  end
end
