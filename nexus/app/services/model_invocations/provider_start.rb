module ModelInvocations
  # The provider-start CAS: the claim, not the call. Only after its commit
  # may IO begin; the durable row records lifecycle only, and the ephemeral
  # context carries the credential by reference to Dispatch.
  class ProviderStart
    STARTED = :started
    # The principal that owns this work no longer may. Terminal.
    AUTHORITY_LOST = :authority_lost
    DEADLINE_PASSED = :deadline_passed
    # Another host got here first. This — not a timer — is what keeps two
    # hosts from running one Attempt.
    ALREADY_STARTED = :already_started
    # The attempt left `prepared` without starting — a cancel or sweep
    # terminalized it meanwhile — and `running` over a terminal is unrecoverable.
    NO_LONGER_PREPARED = :no_longer_prepared
    PAIR_DISALLOWED = :execution_pair_disallowed
    NO_CREDENTIAL = :credential_unusable
    PROVIDER_DISABLED = :provider_disabled

    # What the signer needs and the database must never see: the secret by
    # reference for one send, never serialized.
    class SendContext
      attr_reader :credential, :base_url, :profile, :host

      def initialize(credential:, base_url:, profile:, host:)
        @credential = credential
        @base_url = base_url
        @profile = profile
        @host = host
      end

      def inspect = "#<#{self.class.name} profile=#{@profile.profile_id}>"
      alias_method :to_s, :inspect
    end

    Result = Data.define(:outcome, :attempt, :context) do
      def self.started(attempt, context) = new(outcome: STARTED, attempt: attempt, context: context)
      def self.refused(outcome, attempt: nil) = new(outcome: outcome, attempt: attempt, context: nil)

      def started? = outcome == STARTED
    end

    def self.call(...) = new(...).call

    def initialize(attempt:, host:, base_url:, profile:)
      @attempt = attempt
      @host = host
      @base_url = base_url
      @profile = profile
    end

    def call
      invocation = @attempt.model_invocation
      now = DatabaseClock.now

      refusal = pre_flight_refusal(now)
      return Result.refused(refusal, attempt: @attempt) if refusal

      credential = resolve_credential(invocation, now)
      unless credential.resolved?
        refusal = credential.outcome == :lane_disabled ? PROVIDER_DISABLED : NO_CREDENTIAL
        return Result.refused(refusal, attempt: @attempt)
      end

      claim(invocation, credential.credential)
    end

    private

      # Checks that can refuse before credential resolution, ordered by
      # started state, deadline and execution pair. The started check here
      # is a cheap early exit on an unlocked read; the arbiter is the one
      # inside `claim`.
      def pre_flight_refusal(now)
        return ALREADY_STARTED if @attempt.started?
        return DEADLINE_PASSED if @attempt.deadline_at && now >= @attempt.deadline_at
        unless ExecutionClaim.pair_allowed?(profile: profile, host: @host)
          return PAIR_DISALLOWED
        end

        nil
      end

      def resolve_credential(invocation, now)
        ModelProviders::CredentialResolver.resolve(
          account: invocation.account,
          provider_id: invocation.provider_id,
          credential_lane: profile.credential_lane,
          total_execution_deadline_seconds: deadline_seconds,
          now: now
        )
      end

      # One row lock, the parent invocation's: a CAS on the attempt alone
      # cannot see a cut land on the parent, and would buy a paid call for
      # canceled work. `prepared?`, not `!started?`; the instant is re-read under the lock.
      def claim(invocation, credential)
        invocation.with_lock do
          @attempt.reload
          now = DatabaseClock.now

          if invocation.terminal?
            Result.refused(AUTHORITY_LOST, attempt: @attempt)
          elsif @attempt.started?
            Result.refused(ALREADY_STARTED, attempt: @attempt)
          elsif !@attempt.prepared?
            Result.refused(NO_LONGER_PREPARED, attempt: @attempt)
          elsif @attempt.deadline_at && now >= @attempt.deadline_at
            Result.refused(DEADLINE_PASSED, attempt: @attempt)
          elsif source_stopped?(invocation)
            Result.refused(AUTHORITY_LOST, attempt: @attempt)
          else
            write_start(credential, now)
          end
        end
      end

      # Resolve this invocation's existing owner, then use the same irreversible
      # source cut as publication. No ancestor lock belongs below the invocation
      # lock, and work that already started keeps its ordinary cancellation path.
      def source_stopped?(invocation)
        if (agent_loop = invocation.agent_loop)
          AgentLoops::SourceWork.execution_stopped?(agent_loop)
        elsif invocation.conversation_id
          variant = ConversationTurnVariant.find_by(model_invocation_id: invocation.id)
          variant && AgentLoops::SourceWork.stopped_variant_source?(variant)
        end
      end

      def write_start(credential, now)
        @attempt.update!(
          provider_started_at: now,
          status: "running",
          settlement_state: "pending",
          # FROZEN, never minted. Admission stamped it from the instant the
          # work was admitted; a start that computed its own would restart
          # the clock for an Attempt that had been sitting unclaimed.
          deadline_at: @attempt.deadline_at
        )

        Result.started(@attempt, SendContext.new(
          credential: credential, base_url: base_url, profile: profile, host: @host
        ))
      end

      # The credential is not snapshotted onto the row: the signer using this
      # one is a property of the send, not of a row.

      def deadline_seconds = profile.total_execution_deadline_seconds

      attr_reader :base_url, :profile
  end
end
