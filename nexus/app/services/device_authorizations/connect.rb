module DeviceAuthorizations
  # Connects a device code to the current human's Agent profile; the program
  # identifier chooses create, reconnect or restore. Connect freezes the
  # consequence on the Request and materializes nothing.
  class Connect
    ABSENT_LIVE_RUNNER = "absent".freeze

    Result = Data.define(:outcome, :authorization) do
      class << self
        def connected(authorization)
          new(outcome: :connected, authorization: authorization)
        end

        def stale(authorization)
          new(outcome: :stale, authorization: authorization)
        end

        def blocked(reason)
          new(outcome: reason, authorization: nil)
        end

        private :new
      end
    end

    MappingCandidate = Data.define(:member_id, :steward_id, :branch)
    Mapping = Data.define(:member)

    class << self
      def call(...)
        new(...).call
      end

      def live_runner_precondition(runner)
        runner&.public_id || ABSENT_LIVE_RUNNER
      end
    end

    def initialize(authorization:, connector:, account_wide: false,
                   expected_live_runner: nil)
      unless account_wide == true || account_wide == false
        raise ArgumentError, "account_wide must be boolean"
      end

      @authorization = authorization
      @connector = connector
      @account_wide = account_wide
      @expected_live_runner = expected_live_runner
    end

    def call
      return Result.blocked(:not_authorized) unless connector_authorized?

      # Clock expiry converges independently. A losing connection attempt
      # still leaves an elapsed row terminal instead of rolling expiry back.
      @authorization.materialize_expiry

      # Connect, cancel, and expiry share this pending-row winner; the
      # membership consequence prevents expressing it as one guarded write.
      @authorization.with_lock do
        @authorization.pending? ? connect_pending(@authorization) : Result.stale(@authorization)
      end
    end

    private

      def connect_pending(authorization)
        if authorization.expires_at <= Time.current
          expire(authorization)
        elsif authorization.runner_only_connection?
          connect_runner(authorization)
        else
          # Shape A and the combined shape A+B take this one arm: the agent
          # marker is frozen exactly as branch A freezes it. The runner half
          # of a combined grant is NOT looked up, locked or recorded here —
          # it rides the agent triple's fence (the recorded asymmetry: no
          # second CAS triple), and it has no browser precondition: the page
          # shows no runner block, and a registration that changed while the
          # page was open is caught by Consume's own finder, which re-pairs
          # the live `rho` row or creates one.
          connect_agent(authorization)
        end
      end

      def connect_agent(authorization)
        candidate = mapping_candidate(authorization)
        mapped_member = lock_mapping_candidate(authorization, candidate)
        return Result.stale(authorization) if candidate.member_id && mapped_member.nil?

        connector = lock_connector
        return Result.blocked(:not_authorized) unless connector&.active_human_member?
        if mapped_member && !mapped_member.steward_live?
          return Result.blocked(:shutdown_pending)
        end

        mapping = resolve_mapping(
          authorization,
          connector: connector,
          candidate: candidate,
          mapped_member: mapped_member
        )
        return Result.stale(authorization) unless mapping

        pairing_marker = agent_pairing_marker(mapping.member)
        # The original deadline remains authoritative while the mapping,
        # connector or address locks are contended. Recheck after all required locks
        # and before the frozen-consequence write.
        if authorization.expires_at <= Time.current
          expire(authorization)
        else
          # Frozen here, materialized by Consume: a later pairing or revoke
          # makes this Request stale instead of letting it take the address back.
          if pairing_marker && !pairing_marker.revoked? &&
              !pairing_marker.connection_authority_open?
            return Result.blocked(:shutdown_pending)
          end

          # A combined row keeps the private scope Issue fixed; an agent row
          # carries none.
          authorization.record_connection(
            user: mapping.member,
            connector: connector,
            expected_task_executor: pairing_marker,
            selected_assignment_scope: authorization.selected_assignment_scope
          )
          Result.connected(authorization)
        end
      end

      # Branch B: identity-less. No target authority materializes here either
      # — the Request durably freezes who owns the Runner, and the winning
      # Consume creates or re-pairs the address.
      def connect_runner(authorization)
        connector = lock_connector
        return Result.blocked(:not_authorized) unless connector&.active_human_member?

        existing = runner_for(authorization, connector)
        unless current_live_runner_matches_browser?(existing)
          return Result.blocked(:registration_changed)
        end

        pairing_marker = existing || latest_runner(authorization, connector)
        assignment_scope =
          existing&.assignment_scope ||
          (@account_wide ? "account_wide" : "user_private")
        # Account-wide assignment is an administrator-selected ACL only when
        # creating a registration. A later manager demotion does not rewrite
        # the immutable ACL or prevent that manager from re-pairing it.
        if existing.nil? && @account_wide && !connector.admin?
          Result.blocked(:administrator_required)
        elsif authorization.expires_at <= Time.current
          expire(authorization)
        else
          if pairing_marker && !pairing_marker.revoked? &&
              !pairing_marker.connection_authority_open?
            return Result.blocked(:shutdown_pending)
          end

          authorization.record_connection(
            user: nil,
            connector: connector,
            expected_task_executor: pairing_marker,
            selected_assignment_scope: assignment_scope
          )
          Result.connected(authorization)
        end
      end

      def expire(authorization)
        authorization.materialize_expiry
        Result.stale(authorization)
      end

      def connector_authorized?
        @connector.active_human_member?
      end

      def mapping_candidate(authorization)
        consequence = Consequence.for(authorization, viewer: @connector)
        member = consequence.member
        MappingCandidate.new(
          member_id: member&.id,
          steward_id: member&.steward_id,
          branch: consequence.branch
        )
      end

      def lock_mapping_candidate(authorization, candidate)
        return nil unless candidate.member_id

        # The Agent lifecycle and connection's profile write need one winner.
        # Agent first, then the connector below, preserves the global
        # agent-before-human order shared with steward reassignment.
        member = authorization.account.users
          .where(kind: :agent)
          .where.not(role: :system)
          .where(steward_id: candidate.steward_id)
          .lock
          .find_by(id: candidate.member_id)
        member
      end

      def lock_connector
        @connector.lock!
      end

      def resolve_mapping(authorization, connector:, candidate:, mapped_member:)
        consequence = Consequence.for(authorization, viewer: connector)
        return unless consequence.branch == candidate.branch
        return unless consequence.member&.id == mapped_member&.id
        return if mapped_member && mapped_member.steward_id != connector.id
        return if mapped_member && !mapped_member.steward_live?

        Mapping.new(member: mapped_member)
      end

      def agent_pairing_marker(member)
        return unless member

        TaskExecutor.live.addressing(member).lock.first ||
          TaskExecutor.addressing(member).newest_first.lock.first
      end

      def runner_for(authorization, connector)
        TaskExecutor.live.registered_as(**runner_finder(authorization, connector)).lock.take
      end

      def current_live_runner_matches_browser?(runner)
        @expected_live_runner ==
          self.class.live_runner_precondition(runner)
      end

      # A terminal marker versions true absence and keeps the row from being
      # reaped until this authorization resolves.
      def latest_runner(authorization, connector)
        TaskExecutor.registered_as(**runner_finder(authorization, connector)).newest_first.lock.first
      end

      def runner_finder(authorization, connector)
        {
          account_id: authorization.account_id,
          runner_identifier: authorization.runner_identifier,
          manager_id: connector.id,
        }
      end
  end
end
