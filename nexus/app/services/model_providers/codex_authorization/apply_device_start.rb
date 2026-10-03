module ModelProviders
  module CodexAuthorization
    # The two device-start phases that touch only the session: a granted
    # poll is a coupon the code exchange still has to spend, so a stale poll
    # cannot install anything by construction.
    class ApplyDeviceStart
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
          session = @session.lock!
          task = @task.lock!
          # A result applies only while its own claim is still dispatching and
          # its session still pending: anything else is a continuation that
          # lost its race and must not write.
          next stale unless task.dispatching? && session.state == "pending"
          next late(session, task) unless @now < task.deadline_at
          # Hoisted out of the phases: every phase answers a missing outcome
          # the same way, and per-phase checks made their order matter.
          next ambiguous(session, task) if @outcome.nil?

          case task.exchange_kind
          when "user_code_request" then apply_user_code(session, task)
          when "device_token_poll" then apply_poll(session, task)
          else
            # The credential-installing phases apply through their own suffix.
            # Routing one here would settle its task without ever reaching
            # Credential, silently losing the install.
            raise ArgumentError, "#{task.exchange_kind} does not apply here"
          end
        end
      end

      private

        def apply_user_code(session, task)
          return terminalize(session, task) if @outcome.terminal?

          seal(task, "user_code_issued")
          facts = @outcome.facts
          started = @now
          session.update!(
            device_auth_id: facts.fetch("device_auth_id"),
            user_code: facts.fetch("user_code"),
            # Derived from the reviewed issuer. The response's own expiry and
            # any URI it might offer are not read: one authority for the
            # window, and it is ours.
            verification_uri: CodexAuthorization.verification_url,
            poll_interval_seconds: facts.fetch("interval_seconds"),
            poll_started_at: started,
            authorization_deadline_at:
              started + ModelProviderOAuthSession::AUTHORIZATION_WINDOW_SECONDS,
            progress: "awaiting_user",
            semantic_exchange_kind: "device_token_poll",
            semantic_exchange_ordinal: 0,
            # The first poll may claim immediately.
            next_action_at: started
          )
          Result.new(outcome: :applied, session: session, task: task)
        end

        def apply_poll(session, task)
          return terminalize(session, task) if @outcome.terminal?
          return grant(session, task) if @outcome.ok?

          pending(session, task)
        end

        # A pending poll schedules the next poll, a new step, only inside
        # the window; the window ends the session, never a retry counter.
        def pending(session, task)
          seal(task, "authorization_pending")
          due = @now + session.poll_interval_seconds
          if due >= session.authorization_deadline_at
            session.terminalize(
              state: "expired", outcome: "authorization_deadline_exceeded",
              sanitized_reason: "window_closed", now: @now
            )
            return Result.new(outcome: :expired, session: session.reload, task: task)
          end

          session.update!(
            progress: "polling",
            semantic_exchange_ordinal: session.semantic_exchange_ordinal + 1,
            next_action_at: due
          )
          Result.new(outcome: :applied, session: session, task: task)
        end

        def grant(session, task)
          seal(task, "grant_issued")
          facts = @outcome.facts
          session.update!(
            progress: "exchanging_code",
            authorization_code: facts.fetch("authorization_code"),
            code_challenge: facts.fetch("code_challenge"),
            code_verifier: facts.fetch("code_verifier"),
            # A DISTINCT semantic exchange, so its ordinal restarts the count
            # for a different kind rather than continuing the poll sequence.
            semantic_exchange_kind: "code_exchange",
            semantic_exchange_ordinal: 0,
            next_action_at: @now
          )
          Result.new(outcome: :applied, session: session, task: task)
        end

        def terminalize(session, task)
          seal(task, "terminal_#{@outcome.error}")
          session.terminalize(
            state: "failed", outcome: @outcome.error.to_s,
            sanitized_reason: @normalized_status, now: @now
          )
          Result.new(outcome: :failed, session: session.reload, task: task)
        end

        # A late complete response seals its status but applies nothing; a
        # late poll may have superseded the frozen credential, so it is
        # CAS-marked.
        def late(session, task)
          task.settle(
            state: ModelProviderOAuthTask::SPENT,
            normalized_status: InstallCredential::LATE_STATUS,
            result_kind: InstallCredential::LATE_RESULT_KIND,
            now: @now
          )
          # Only a POLL can have moved a credential upstream — the same split
          # the ambiguity path makes, and for the same reason.
          mark_frozen_credential(session) if task.exchange_kind == "device_token_poll"
          Result.new(outcome: :late, session: session, task: task)
        end

        def ambiguous(session, task)
          task.settle(
            state: ModelProviderOAuthTask::SPENT, normalized_status: @normalized_status,
            result_kind: "no_response",
            now: @now
          )
          mark_frozen_credential(session) if task.exchange_kind == "device_token_poll"
          Result.new(outcome: :ambiguous, session: session, task: task)
        end

        # Only the exact triple this session froze. The CAS is the point: a
        # credential that has since been replaced is a different credential,
        # and this observation says nothing about it.
        def mark_frozen_credential(session)
          return if session.source_credential_public_id.nil?

          MarkReauthorizationRequired.call(
            account: session.account, provider_id: session.provider_id,
            lineage_id: session.source_authorization_lineage_id,
            expected_generation: session.source_generation,
            reason: "authorization_ambiguous"
          )
        end

        def seal(task, kind)
          task.settle(
            state: ModelProviderOAuthTask::ANSWERED, normalized_status: @normalized_status,
            result_kind: kind, now: @now
          )
        end

        def stale = Result.new(outcome: :stale, session: @session, task: @task)
    end
  end
end
