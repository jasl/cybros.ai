require "monitor"
require_relative "lineage/status"
require_relative "lineage/retirement"
require_relative "lineage/shutdown"

module Rho
  class Daemon
    # Every fact that moves together when a credential lineage begins, rotates
    # or dies, under the core's one non-leaf lock; `about` is the credential object a caller captured, compared by identity.
    class Lineage
      include Retirement
      include Shutdown

      AUTHORITY_OBSERVATION_INTERVAL = 60
      VERIFY_WINDOW = 300
      LOST_REPORT = { planes: {}, lost: true }.freeze
      NOT_DURABLE = "the renewed credential is live but was not written down".freeze
      JOINABLE_PHASES = %i[starting pending pending_runner activating].freeze
      # The two runner slots, `:runner` first (see Retirement).
      SLOTS = %i[runner agent_runner].freeze
      # `expected:` omitted means unchecked; `nil` means "no credential", which
      # is what a recovery after a terminal loss legitimately expects.
      UNCHECKED = Object.new.freeze

      # `kind` says WHAT was adopted: rho's own `dedicated`
      # workspace, or a steward-created `room` the knob named — a person
      # reading `rho status` must tell the two apart, because `rho do
      # --agent` has a lawful peer only in a room.
      Workspace = Data.define(:state, :public_id, :name, :kind, :code) do
        def self.pending = new(state: "pending", public_id: nil, name: nil, kind: nil, code: nil)

        def self.adopted(public_id:, name:, kind: "dedicated") =
          new(state: "adopted", public_id: public_id, name: name, kind: kind, code: nil)

        def self.error(code:) = new(state: "error", public_id: nil, name: nil, kind: nil, code: code)

        def adopted? = state == "adopted"

        def document = { state: state, public_id: public_id, name: name, kind: kind, code: code }.compact
      end

      Observation = Data.define(:about, :report, :measured_at)

      # What a lineage edge hands the caller to stop and close OUTSIDE the
      # monitor; registry removal inside it is the authority cut. The
      # executor sockets ride here beside the member one, one
      # per runner slot: what closes them is the lineage, never the stream
      # fiber.
      Retired = Data.define(:runs, :realtime, :executor_realtimes, :runners) do
        def self.none = new(runs: [], realtime: nil, executor_realtimes: [], runners: [])

        def clients = (runs.filter_map(&:realtime) + [realtime] + executor_realtimes).compact.uniq
      end

      Adoption = Data.define(:changed, :from, :retired)
      Joined = Data.define(:connection)
      Slot = Data.define(:connection, :poller, :last_cancel_succeeded, :phase, :bootstrapping, :credentials)
      Facts = Data.define(:state, :connection_document, :identity, :generation)
      Snapshot = Data.define(:phase, :credentials, :identity, :lost, :observation, :workspace,
        :connection_document, :connection_error)

      def initialize(clock:, realtime_factory:)
        @clock = clock
        @realtime_factory = realtime_factory
        @monotonic = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @monitor = Monitor.new # no IO under it: test/code_style/lineage_lock_test.rb
        @handlers_changed = @monitor.new_cond
        @maintenance_changed = @monitor.new_cond
        @phase = :stopped
        @stopping = false
        @bootstrapping = true
        @identity = nil
        @credentials = nil
        @observation = nil
        @lost = false
        @verified_at = nil
        @connection_error = nil
        @workspace = Workspace.pending
        @connection = nil
        @poller = nil
        @last_cancel_succeeded = false
        @runs = {}
        @realtime = nil
        @realtime_about = nil
        @executor_realtimes = {}
        @executor_realtime_abouts = {}
        @runners = {}
        @tool_envs = {}
        @runner_abouts = {}
        @control_operations = 0
        @maintenance_requested = false
        @maintenance_running = false
        @maintenance_stopped = false
        @generation = 0
      end

      # ---- reads: one snapshot each ----

      def phase = @monitor.synchronize { @phase }

      def stopping? = @monitor.synchronize { @stopping }

      def bootstrapping? = @monitor.synchronize { @bootstrapping }

      def identity = @monitor.synchronize { @identity }

      def credentials = @monitor.synchronize { @credentials }

      def workspace = @monitor.synchronize { @workspace }

      def connection = @monitor.synchronize { @connection }

      def runs = @monitor.synchronize { @runs.values }

      def run(public_id) = @monitor.synchronize { @runs[public_id] }

      def runner(slot = :runner) = @monitor.synchronize { @runners[slot] }

      # Every placed runner, `:runner` first.
      def runners = @monitor.synchronize { SLOTS.filter_map { |slot| @runners[slot] } }

      def tool_env(slot = :runner) = @monitor.synchronize { @tool_envs[slot] }

      def realtime = @monitor.synchronize { @realtime }

      def executor_realtime(slot = :runner) = @monitor.synchronize { @executor_realtimes[slot] }

      def maintenance_running? = @monitor.synchronize { @maintenance_running }

      def holds?(about) = @monitor.synchronize { @credentials.equal?(about) }

      def current?(about) = @monitor.synchronize { !@stopping && @credentials.equal?(about) }

      def observation_fresh?(about) = @monitor.synchronize { fresh_locked?(about) }

      def status_document = Status.document(snapshot)

      def snapshot
        @monitor.synchronize do
          Snapshot.new(
            phase: @phase, credentials: @credentials, identity: @identity, lost: @lost,
            observation: @observation, workspace: @workspace,
            connection_document: @connection&.to_h, connection_error: @connection_error
          )
        end
      end

      # The workspace and the credential a handler acts with, adopted by the
      # SAME lineage.
      def member_plane_snapshot = @monitor.synchronize { [@workspace, @credentials] }

      def slot_snapshot
        @monitor.synchronize do
          Slot.new(
            connection: @connection, poller: @poller, last_cancel_succeeded: @last_cancel_succeeded,
            phase: @phase, bootstrapping: @bootstrapping, credentials: @credentials
          )
        end
      end

      def joinable = @monitor.synchronize { joinable_locked }

      def announcement_facts
        @monitor.synchronize do
          Facts.new(
            state: @phase.to_s, connection_document: @connection&.to_h,
            identity: @identity, generation: @generation
          )
        end
      end

      # ---- lineage edges ----

      # Rotation updates the same OAuth object; a different object is a
      # replacement Agent lineage inherits no followers or Agent handler.
      # An unchanged independent Runner keeps its runtime. A same-object
      # re-adopt only refreshes the observation.
      def adopt(identity:, credentials:, authority_report: nil)
        @monitor.synchronize do
          if @phase == :active && @credentials.equal?(credentials) && @identity.equal?(identity)
            if authority_report
              @observation = Observation.new(about: credentials, report: authority_report, measured_at: @clock.call)
            end
            next Adoption.new(changed: false, from: @phase, retired: Retired.none)
          end

          retired = retire_for_adoption_locked(credentials)
          from = @phase
          @identity = identity
          @credentials = credentials
          @observation =
            authority_report && Observation.new(about: credentials, report: authority_report, measured_at: @clock.call)
          @connection_error = nil
          @lost = false
          @last_cancel_succeeded = false
          @verified_at = nil
          # Ensure-Workspace starts over for every adopted lineage, and the
          # dirty bit wakes maintenance now rather than after the interval.
          @workspace = Workspace.pending
          @maintenance_requested = true
          @maintenance_changed.signal
          @phase = :active
          @generation += 1
          Adoption.new(changed: true, from: from, retired: retired)
        end
      end

      # The stored lineage the daemon booted with is already terminally lost:
      # the identity is held so status can name it, and the loss is recorded
      # about the credentials that proved it.
      def adopt_lost(identity:, credentials:, report:)
        @monitor.synchronize do
          @identity = identity
          @credentials = credentials
          lose_locked(credentials, report)
        end
      end

      def lose(about: nil, unless_stopping: false, report: nil)
        @monitor.synchronize do
          next nil if unless_stopping && @stopping
          next nil if about && !@credentials.equal?(about)

          lose_locked(@credentials, report)
        end
      end

      def commit_workspace(about, workspace)
        @monitor.synchronize do
          next false if @stopping || !@credentials.equal?(about)

          @workspace = workspace
          true
        end
      end

      def observe(about, report)
        @monitor.synchronize do
          next false if @stopping || !@credentials.equal?(about)

          @observation = Observation.new(about: about, report: report, measured_at: @clock.call)
          true
        end
      end

      def record_not_durable(about, unless_stopping:)
        @monitor.synchronize do
          next false if unless_stopping && @stopping
          next false unless @credentials.equal?(about)

          @connection_error = NOT_DURABLE
          true
        end
      end

      def record_connection_error(message) = @monitor.synchronize { @connection_error = message }

      # A stale read wakes the one maintenance worker; a burst of them folds
      # into the cycle already pending or running.
      def request_probe
        @monitor.synchronize do
          next if @stopping || @credentials.nil?
          next if @maintenance_requested || @maintenance_running
          next if fresh_locked?(@credentials)

          @maintenance_requested = true
          @maintenance_changed.signal
        end
      end

      # The credentials to verify, or nil when there are none or the window
      # has not passed.
      def mark_verified(now)
        @monitor.synchronize do
          next nil if @credentials.nil?
          next nil if @verified_at && now - @verified_at < VERIFY_WINDOW

          @verified_at = now
          @credentials
        end
      end

      def transition(phase)
        @monitor.synchronize do
          from = @phase
          @phase = phase
          @generation += 1
          from
        end
      end

      def begin_bootstrap = @monitor.synchronize { @bootstrapping = true }

      def finish_bootstrap = @monitor.synchronize { @bootstrapping = false }

      # ---- the ceremony slot ----

      def claim_slot(candidate, expected: UNCHECKED)
        @monitor.synchronize do
          next :stopping if @stopping

          joinable = joinable_locked
          next Joined.new(connection: joinable) if joinable
          unless expected.equal?(UNCHECKED) || @credentials.equal?(expected)
            next(@phase == :active ? :already_connected : :stale)
          end

          @connection = candidate
          @last_cancel_succeeded = false
          @generation += 1
          :claimed
        end
      end

      # `pending` becomes visible and its poller is set in one section: there
      # is no cancelable phase with nobody to cancel.
      def publish_pending(connection, &work)
        @monitor.synchronize do
          connection.publish_pending(notify: false)
          @poller = Thread.new(&work)
          @generation += 1
          connection.to_h
        end
      end

      def release_slot(connection, canceled: false)
        @monitor.synchronize do
          next false unless @connection.equal?(connection)

          @connection = nil
          if canceled
            @connection_error = nil
            @last_cancel_succeeded = true
          end
          @generation += 1
          true
        end
      end

      def release_poller(thread) = @monitor.synchronize { @poller = nil if @poller.equal?(thread) }

      private

        def fresh_locked?(about)
          !@observation.nil? &&
            @observation.about.equal?(about) &&
            @clock.call - @observation.measured_at < AUTHORITY_OBSERVATION_INTERVAL
        end

        def joinable_locked
          return nil if @connection.nil?
          return @connection if JOINABLE_PHASES.include?(@connection.phase)
          return @connection if @connection.phase == :active && !@connection.oauth.equal?(@credentials)

          nil
        end

        # A late terminal report concerns `current`, not a replacement
        # converging beside it: only the adopted connection whose OAuth object
        # is the lost lineage is dropped with it.
        def lose_locked(current, report)
          if current
            @observation = Observation.new(about: current, report: report || LOST_REPORT, measured_at: @clock.call)
          end
          @lost = true
          @credentials = nil
          @workspace = Workspace.pending
          retired = retire_locked
          preserve = @connection && (@connection.phase != :active || !@connection.oauth.equal?(current))
          @connection = nil unless preserve
          from = @phase
          @phase = :disconnected
          @generation += 1
          Adoption.new(changed: true, from: from, retired: retired)
        end
    end
  end
end
