module ModelInvocations
  # Compile, claim, send, apply — the one sequence both hosts run,
  # differing only in host name and stream sink. PAIR_DISALLOWED is
  # write-free: work another host will run is not this host's to terminalize.
  class ExecuteAttempt
    # Which pre-IO terminal class each refusal deserves, judged here for
    # both hosts.
    TERMINAL_CLASSES = {
      ProviderStart::AUTHORITY_LOST => "canceled",
      ProviderStart::DEADLINE_PASSED => "timed_out",
      ProviderStart::NO_CREDENTIAL => "failed",
      ProviderStart::PROVIDER_DISABLED => "failed",
    }.freeze

    # The ordinary races a host is designed to lose quietly: another host is
    # running the work, it already ended, or the lane is not this host's to
    # run. Either way there is nothing here to write.
    WRITE_FREE = [
      ProviderStart::ALREADY_STARTED,
      ProviderStart::NO_LONGER_PREPARED,
      ProviderStart::PAIR_DISALLOWED,
    ].freeze

    def self.call(...) = new(...).call

    # `settled` is the host's hook, called once the stream has said its
    # last word: from then on nothing is left to stop paying for, and a
    # host that cuts by fiber raise must leave the finish alone.
    def initialize(attempt:, host:, stream_sink: nil, settled: nil)
      @attempt = attempt
      @host = host
      @stream_sink = stream_sink
      @settled = settled
    end

    def call
      # Compiling comes first: a preparation failure after the claim is
      # unsettleable, since both pre-IO writers refuse a started attempt.
      invocation = @attempt.model_invocation

      # The invocation keeps the product choice; the send takes every wire
      # fact from the current effective catalog, never falling through to another model.
      catalog = ModelCatalog.current
      effective_catalog = ModelSelection::Resolver.effective_provider_catalog(
        invocation.account, catalog, invocation.provider_id
      )
      provider = effective_catalog.providers[invocation.provider_id]
      return refuse_uncompilable(:unknown_provider) if provider.nil?
      unless effective_catalog.policies[invocation.provider_id]&.enabled
        return refuse_uncompilable(:provider_disabled)
      end

      catalog_ref = "#{invocation.provider_id}/#{invocation.model_ref}"
      entry = effective_catalog.models[catalog_ref]
      return refuse_uncompilable(:unknown_model) if entry.nil?
      if effective_catalog.hidden_models.include?(catalog_ref)
        return refuse_uncompilable(:model_hidden)
      end

      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: catalog_ref, provider: provider, model: entry
      )
      return refuse_uncompilable(:unsupported_workload) unless profile.workload == invocation.workload

      base_url = ModelCatalog.provider_base_url(invocation.provider_id, snapshot: effective_catalog)
      built = ModelRequests::Build.call(
        invocation: invocation, profile: profile, base_url: base_url, host: @host,
        reasoning_context: entry.dig("capabilities", "reasoning", "default_context")
      )
      return refuse_uncompilable(built.refusal) unless built.built?

      start = ProviderStart.call(
        attempt: @attempt, host: @host, base_url: base_url, profile: profile
      )
      return dispatch(start, built.request) if start.started?

      settle_refusal(start.outcome)
      nil
    end

    private

      # The sink is told before ApplyResult commits: a retry's rollback
      # marker must land while the row is still this attempt's, and every
      # other end settles the billed tail while the delta gate still accepts.
      # The settle OWNS that tail — a timer flush still in flight is joined
      # inside it (DeltaCoalescing) — so nothing of the narration is left
      # racing the terminal status ApplyResult commits next. A DECLINED
      # answer, and a failure nothing retries, is withdrawn instead of
      # settled: ApplyResult stores none of it, so a follower must drop what
      # streamed rather than keep a partial the row will never hold.
      def dispatch(start, request)
        invocation = start.attempt.model_invocation
        # The attempt is dialled: the start claim committed, the first
        # byte not yet asked for — the one instant no row or settled item
        # narrates, so the hosted sink mints `round_started` here.
        notify_sink(:on_attempt_started, invocation, start.attempt)
        sent = Dispatch.call(
          attempt: start.attempt, context: start.context, request: request
        ) { |event| notify_sink(:on_event, invocation, event) }
        if will_requeue?(sent, invocation)
          notify_sink(:on_retry, invocation)
        elsif ApplyResult.declined?(invocation: invocation, outcome: sent)
          notify_sink(:on_refused, invocation)
        elsif ApplyResult.finish_error?(invocation: invocation, outcome: sent)
          notify_sink(:on_failed, invocation)
        elsif sent.succeeded?
          notify_sink(:on_stream_settled, invocation)
        else
          notify_sink(:on_failed, invocation)
        end
        # The stream's last word is said and the sink has its tail; the
        # flip and the wakes that follow are a finish, never a cut.
        @settled&.call
        result = ApplyResult.call(attempt: start.attempt, outcome: sent)
        # Latency sugar; the recurring passes are the floor. A terminal
        # freed capacity, so admission refills now; a requeue named its
        # cooldown, so admission wakes when it expires.
        if result.requeued?
          # Reloaded: ApplyResult wrote the cooldown through its own loaded
          # row, not this cached association.
          AdmitQueuedWorkJob.set(
            wait_until: result.attempt.model_invocation.reload.next_admission_at
          ).perform_later
        else
          invocation.converge_owner_later
          # At the provider's floor when the terminal arrived with one (a
          # budget spent on a 429): a pass now would find the lane held.
          # `wait_until: nil` runs now, so every other terminal is unchanged.
          AdmitQueuedWorkJob.set(wait_until: result.provider_floor_at).perform_later
        end
        result
      end

      def will_requeue?(sent, invocation)
        return false if sent.succeeded?

        ApplyResult.transient_error?(sent.error) &&
          !AttemptOrdinal.budget_spent?(invocation, ordinal: @attempt.ordinal)
      end

      # A sink failure costs the narration and never the answer: a billed
      # provider result outranks its replay copy, so the sink goes quiet.
      def notify_sink(method, *args)
        return if @stream_sink.nil? || @sink_failed

        @stream_sink.public_send(method, *args)
      rescue ModelRunner::ExecutionAborted
        # A host abort surfacing inside a sink call is the host's message,
        # never the sink's failure: it unwinds, or a shutdown fiber is unkillable.
        raise
      rescue StandardError => error
        @sink_failed = true
        Rails.error.report(error, handled: true, severity: :error,
          context: { event: "stream_sink_failed", attempt: @attempt.public_id, hook: method })
        nil
      end

      # No pre-IO refusal takes a catalog-generation back edge: a local
      # revision proves nothing about a remote provider.
      def refuse_uncompilable(reason)
        end_work("failed", reason)
        nil
      end

      def settle_refusal(outcome)
        return if WRITE_FREE.include?(outcome)

        # Anything ELSE reaching here has no writer, and the last time that
        # was silent the Invocation sat `running` forever — so an unknown
        # outcome raises rather than teaching a host to lose work quietly.
        terminal = TERMINAL_CLASSES.fetch(outcome) do
          raise "no terminal class for provider-start outcome #{outcome.inspect}"
        end
        end_work(terminal, outcome)
      end

      # The ordinal and the invocation end together, or `RunningCapacity`
      # counts the stuck row forever; `terminalize` keeps the first winner.
      def end_work(terminal, reason)
        with_authority do |invocation|
          result = CancelUnstarted.call(attempt: @attempt, terminal_status: terminal)
          next result unless result.terminalized?

          invocation.terminalize(status: terminal, reason_key: reason)
          result
        end.tap do
          @attempt.model_invocation.converge_owner_later
        end
      end

      # The lock prefix both writers require and neither takes for itself:
      # the principals by the pinned order, then the Invocation.
      def with_authority
        invocation = @attempt.model_invocation
        ApplicationRecord.transaction do
          PrincipalLocks.descend(*principals)
          invocation.lock!
          yield invocation
        end
      end

      # The FROZEN principals, read off the Attempt — the consumer and payer
      # the admission was actually made against.
      def principals
        public_ids = [@attempt.consumer_public_id, @attempt.payer_public_id].compact.uniq
        return [] if public_ids.empty?

        User.where(public_id: public_ids).to_a
      end
  end
end
