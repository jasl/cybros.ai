module ModelProviders
  module CodexAuthorization
    # The only path from an authorization to a usable credential, applied
    # forward (Policy, Session, Task, Credential) after provider IO. Three
    # preconditions rechecked under the lock; miss one and this continuation lost its race.
    class InstallCredential
      # The issuer's relative lifetime against the injected instant, never
      # the JWT `exp` the same response carries.

      # The same status the stale-dispatch sweep writes, one fact one
      # spelling; the result kind says this saw a complete response it may not act on.
      LATE_STATUS = "dispatch_deadline_exceeded".freeze
      LATE_RESULT_KIND = "late_response".freeze

      # `normalized_status` is the transport's own word for the step: the
      # HTTP status it answered with, or the client's error class when it did
      # not (Advance spells it, this side records it).
      def self.call(session:, task:, outcome:, normalized_status:, now: Time.current)
        new(session:, task:, outcome:, normalized_status:, now:).call
      end

      def initialize(session:, task:, outcome:, normalized_status:, now:)
        @session = session
        @task = task
        @outcome = outcome
        @normalized_status = normalized_status
        @now = now
      end

      def call
        ModelProviderOAuthSession.transaction do
          @policy = ModelProviderPolicy.lock.find_by!(
            account_id: @session.account_id, provider_id: @session.provider_id
          )
          session = @session.lock!
          task = @task.lock!
          next stale(session) unless task.dispatching? && session.state == "pending"
          next late(session, task) unless @now < task.deadline_at
          next ambiguous(session, task) if @outcome.nil?
          next retry_later(session, task) if @outcome.retryable?
          next failed(session, task) if @outcome.terminal?

          install(session, task)
        end
      end

      private

        def install(session, task)
          seal(task, "tokens_installed")
          facts = @outcome.facts
          expires_at = @now + facts.fetch("expires_in_seconds")

          # The session terminalizes FIRST: only a session whose first terminal
          # outcome is `completed` may install, and making that the first write
          # means a racing revoke either wins the whole suffix or loses it.
          completed = session.terminalize(state: "completed", outcome: "authorized", now: @now)
          # Lost the first-terminal race to a revoke or an expiry: that writer
          # already decided what this session was, and it was not this.
          return stale(session) if completed.nil?

          installed = InstallOAuthPair.call(
            account: session.account, provider_id: session.provider_id,
            access_token: facts.fetch("access_token"), refresh_token: facts.fetch("refresh_token"),
            # The lineage this session OWNS: newly minted for a device start,
            # continued for a refresh.
            lineage_id: session.authorization_lineage_id,
            # The CAS target both kinds land on: a slower predecessor can never
            # overwrite a newer success.
            expected_lineage_id: session.source_authorization_lineage_id,
            expected_generation: session.source_generation,
            expires_at: expires_at,
            provider_account_identity: account_identity(facts.fetch("id_token"))
          )
          return Result.new(outcome: installed.outcome, session: completed, task: task) unless
            installed.done?

          @policy.update!(enabled: true) if session.device_start? && !@policy.enabled?
          Result.new(outcome: :installed, session: completed, task: task, credential: installed.credential)
        end

        # The `chatgpt_account_id` claim is the codex lane's
        # `ChatGPT-Account-ID` header (ModelCatalog::AssembleClient, as
        # codex-rs bearer_auth_provider.rs sends it): an unparsable token
        # still installs, and the header is then omitted, as codex omits
        # it for `None`.
        def account_identity(id_token)
          payload = id_token.split(".")[1].to_s
          padded = payload + ("=" * ((4 - payload.length % 4) % 4))
          claims = ActiveSupport::JSON.decode(Base64.urlsafe_decode64(padded))
          claims.dig("https://api.openai.com/auth", "chatgpt_account_id")
        rescue ArgumentError, JSON::ParserError, NoMethodError
          nil
        end

        # A transient failure ends the session and a later refresh is a new
        # one: a resend may already have been processed. Nothing is marked — a
        # bad minute is not a dead credential.
        def retry_later(session, task)
          seal(task, "retryable_failure")
          session.terminalize(
            state: "failed", outcome: "provider_error", sanitized_reason: @normalized_status,
            now: @now
          )
          Result.new(outcome: :retryable, session: session.reload, task: task)
        end

        # No partial pair survives a failed exchange. A refresh failure also
        # disables the credential it froze — reached only on a permanent
        # classification, so no transient failure sends a human to reauthorize.
        def failed(session, task)
          seal(task, "terminal_#{@outcome.error}")
          session.terminalize(
            state: "failed", outcome: @outcome.error.to_s, sanitized_reason: @normalized_status,
            now: @now
          )
          mark_frozen_credential(session, @outcome.error.to_s) if session.token_refresh?
          Result.new(outcome: :failed, session: session.reload, task: task)
        end

        # Only `now < deadline_at` may apply: a late response seals its
        # status but installs nothing. A device session waits for its window;
        # a refresh has none and closes as ambiguous here.
        def late(session, task)
          task.settle(
            state: ModelProviderOAuthTask::SPENT,
            normalized_status: LATE_STATUS, result_kind: LATE_RESULT_KIND,
            now: @now
          )
          close_ambiguous_refresh(session, LATE_STATUS)
          # Same reasoning as the ambiguity path: the exchange may have spent
          # its single-use grant upstream, so the frozen triple is marked.
          mark_frozen_credential(session, LATE_RESULT_KIND)
          Result.new(outcome: :late, session: session, task: task)
        end

        # The exchange may have spent its one-use grant upstream, so the
        # frozen triple is marked for a human either way.
        def ambiguous(session, task)
          task.settle(
            state: ModelProviderOAuthTask::SPENT, normalized_status: @normalized_status,
            result_kind: "no_response",
            now: @now
          )
          close_ambiguous_refresh(session, @normalized_status)
          mark_frozen_credential(session, "authorization_ambiguous")
          Result.new(outcome: :ambiguous, session: session, task: task)
        end

        def close_ambiguous_refresh(session, reason)
          return unless session.token_refresh?

          session.terminalize(
            state: "failed", outcome: "ambiguous_delivery",
            sanitized_reason: reason, now: @now
          )
        end

        # Only the exact triple this session froze. A credential that has been
        # replaced since is a different credential, and neither this failure
        # nor this ambiguity says anything about it.
        def mark_frozen_credential(session, reason)
          return if session.source_credential_public_id.nil?

          MarkReauthorizationRequired.call(
            account: session.account, provider_id: session.provider_id,
            lineage_id: session.source_authorization_lineage_id,
            expected_generation: session.source_generation,
            reason: reason.first(64)
          )
        end

        def seal(task, kind)
          task.settle(
            state: ModelProviderOAuthTask::ANSWERED, normalized_status: @normalized_status,
            result_kind: kind, now: @now
          )
        end

        def stale(session) = Result.new(outcome: :stale, session: session, task: @task)
    end
  end
end
