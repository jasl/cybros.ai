module ModelInvocations
  # The admission pass, application-level because Solid Queue cannot rank per owner over
  # layered caps. The advisory lock serializes one race, count-then-claim, per candidate;
  # ranking and caps are different jobs. A lane under the provider's own floor (`Retry-After`)
  # is left out of the window.
  class AdmitQueuedWork
    CANDIDATE_WINDOW = 100
    # The ranking is a window function, so unbounded it is O(N log N) in a
    # backlog that grows exactly when passes are densest; the rotation runs
    # over the oldest thousand waiters instead.
    FAIRNESS_WINDOW = 1_000
    ADVISORY_LOCK = "model_invocations:admit".freeze

    Result = Data.define(:admitted, :rejected, :lock_contended, :more) do
      def lock_contended? = lock_contended
      # A full batch says nothing about what is left, so the caller
      # re-triggers rather than admitting one batch a minute.
      def more? = more
    end

    def self.call(...) = new(...).call

    # `lock_timeout_seconds: 0` is the reactor's shape: try once, and on
    # contention hand the trigger to the scheduled job rather than block a
    # thread that is also carrying in-flight streams.
    def initialize(batch_size: 10, lock_timeout_seconds: 5)
      @batch_size = batch_size
      @lock_timeout_seconds = lock_timeout_seconds
      @admitted = []
      @rejected = 0
      @lock_contended = false
      @catalogs = {}
    end

    def call
      queue = candidates
      @catalog_snapshot = ModelCatalog.current unless queue.empty?

      # EVERY disposition consumes, which is what makes it fair: a candidate
      # that keeps being rejected must not keep being offered ahead of the
      # next owner's first row.
      while @admitted.length < @batch_size && (candidate = queue.shift)
        break if @lock_contended

        admitted?(candidate)
      end

      wake_admitted
      Result.new(admitted: @admitted, rejected: @rejected, lock_contended: @lock_contended,
                 more: @admitted.length >= @batch_size)
    end

    private

      # Lock-free discovery, ranked before the limit so every owner's first row precedes anyone's second.
      # Priority is an in-lane tie break, never a global rank; the due test is an explicit OR because the
      # array form stops filtering.
      def candidates
        ModelInvocation
          .from(ranked_queued_invocations, :ranked)
          .order(:lane_rank, :created_at, :id)
          .limit(CANDIDATE_WINDOW)
          .pluck(:id, :creating_user_id)
          .map do |id, creating_user_id|
            Candidate.new(id: id, creating_user_id: creating_user_id)
          end
      end

      def ranked_queued_invocations
        ModelInvocation
          .from(due_queued_window, :due)
          .select(
            :id, :created_at, :creating_user_id,
            "row_number() OVER (PARTITION BY creating_user_id " \
              "ORDER BY priority DESC, created_at, id) AS lane_rank"
          )
      end

      # The oldest eligible rows in arrival order, off the queued_scan index;
      # the LIMIT stops the walk. One clock for both predicates.
      def due_queued_window
        now = DatabaseClock.now
        ModelInvocation
          .where(status: "queued")
          .merge(
            ModelInvocation.where(next_admission_at: nil)
              .or(ModelInvocation.where(next_admission_at: ..now))
          )
          # THE PROVIDER'S FLOOR: a lane the provider asked us to leave alone
          # until a time is not offered — its rows keep their place and re-enter
          # in arrival order when the clock passes. One NOT EXISTS on the unique
          # index; a floored lane costs the pass nothing.
          .where.not(
            ModelProviderRuntimeState.floored_at(now)
              .where(account_id: ModelInvocation.arel_table[:account_id],
                     provider_id: ModelInvocation.arel_table[:provider_id])
              .arel.exists
          )
          .select(:id, :created_at, :creating_user_id, :priority)
          .order(:created_at, :id)
          .limit(FAIRNESS_WINDOW)
      end

      # Admission does not compile the request: `ModelRequests::Build` runs in
      # the run job immediately before IO, so no upload serializes every
      # admitter. Admission's job is the claim.
      def admitted?(candidate)
        outcome = nil
        acquired = ModelInvocation.with_advisory_lock(
          ADVISORY_LOCK, timeout_seconds: @lock_timeout_seconds, disable_query_cache: true
        ) do
          outcome = claim(candidate)
          true
        end

        unless acquired == true
          @lock_contended = true
          return false
        end

        @rejected += 1 unless outcome
        outcome
      end

      # One transaction, so the counts that authorized the claim commit with
      # it: no pre-claim check may create a bypass lane.
      def claim(candidate)
        ApplicationRecord.transaction do
          # The principals FIRST: `users` ranks far above `model_invocations`,
          # so the row lock below has to come after them or this pass descends
          # the ladder backwards relative to every other writer.
          principals = Principals.for(candidate)
          next false if principals.nil?

          PrincipalLocks.descend(*principals.all)
          # A steward reassignment that committed while this waited names
          # another payer; the next pass locks that Human from the top of the ladder.
          next false unless principals.payer_still_current?

          invocation = locked_invocation(candidate.id)
          next false if invocation.nil?
          next false unless invocation.queued?

          admit(invocation, principals)
        end
      end

      # `SKIP LOCKED` inside the transaction, the only place it means
      # anything: a row another admitter holds is somebody else's work.
      def locked_invocation(invocation_id)
        ModelInvocation.lock("FOR UPDATE SKIP LOCKED").find_by(
          id: invocation_id, status: "queued"
        )
      end

      # Capacity and admission use the same effective account catalog.
      def capacity_for(invocation, principals)
        RunningCapacity.available?(
          provider_id: invocation.provider_id,
          workload: invocation.workload,
          payer_id: principals.payer.id,
          catalog: effective_catalog_for(invocation.account)
        )
      end

      # Validity is checked first: a retired provider has no ceiling to
      # read, so asked the other way round a retirement was an exception out
      # of every pass rather than a typed `unknown_model`.
      def admit(invocation, principals)
        quote = AdmissionCandidate.call(
          invocation: invocation, catalog: effective_catalog_for(invocation.account)
        )
        return terminalize(invocation, quote.refusal) unless quote.accepted?
        if quote.shape == "priced" && budget_exhausted?(principals.payer)
          return terminalize(invocation, "budget_exhausted")
        end
        return false unless capacity_for(invocation, principals)

        # The attempt budget is enforced by `ApplyResult#requeue_transient`
        # alone, so a queued candidate always has budget left; an active
        # sibling is a deferral, not a terminal.
        ordinal = AttemptOrdinal.next_for(invocation)
        return false unless ordinal.allocated?

        usage = AdmitUsage.call(
          invocation: invocation, quote: quote,
          consumer: principals.consumer, payer: principals.payer, ordinal: ordinal.ordinal
        )
        invocation.update!(status: "running")
        @admitted << Admission.new(invocation: invocation, attempt: usage.attempt)
        true
      end

      # The soft spend guard: an unlocked read, so in-flight work can overspend
      # by a bounded amount in exchange for holding nothing. Priced work only;
      # no budget means no cap.
      def budget_exhausted?(payer)
        amounts = payer.usage_budgets.usable_at(DatabaseClock.now)
          .pick(:credited_amount, :debited_amount)
        return false if amounts.nil?

        credited, debited = amounts
        debited >= credited
      end

      # An invalid selection or exhausted priced budget terminalizes — caps never
      # drop on their own — and the reason is frozen on the row, the one
      # place an operator or the public projection reads it.
      def terminalize(invocation, reason)
        invocation.terminalize(status: "failed", reason_key: reason)
        invocation.converge_owner_later
        false
      end

      # After commit, and best effort: the wake is a latency accelerator and
      # never a correctness step.
      def wake_admitted
        Wake.after_commit_batch(attempts: @admitted.map(&:attempt))
      end

      # One overlay composition per Account and one file snapshot per pass:
      # a coherent catalog without a persisted version token.
      def effective_catalog_for(account)
        @catalogs[account.id] ||= ModelSelection::Resolver.effective_catalog(
          account, @catalog_snapshot
        )
      end

    Admission = Data.define(:invocation, :attempt)
    Candidate = Data.define(:id, :creating_user_id)

    # Proposes the rows to lock; `payer_still_current?` decides from the
    # locked Agent whether a reassignment made the proposed Human stale.
    Principals = Data.define(:consumer, :payer) do
      def self.for(candidate)
        creator = User.find_by(id: candidate.creating_user_id)
        return if creator.nil?

        new(consumer: creator, payer: creator.agent_member? ? creator.steward : creator)
      end

      def all = [consumer, payer].compact.uniq

      def payer_still_current?
        if consumer.agent_member?
          !payer.nil? && consumer.steward_id == payer.id
        else
          consumer == payer
        end
      end
    end
  end
end
