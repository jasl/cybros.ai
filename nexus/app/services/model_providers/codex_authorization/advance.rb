module ModelProviders
  module CodexAuthorization
    # One step: claim, send, apply. The claim commits before the request
    # goes out and the apply opens after the wire is finished, so no lock
    # crosses a stranger's latency. Delivery is the transport's question, not the protocol's.
    class Advance
      def self.call(session:, now: Time.current, client: nil)
        new(session:, now:, client:).call
      end

      def initialize(session:, now:, client:)
        @session = session
        @now = now
        @client = client
      end

      def call
        claim = Claim.call(session: @session, now: @now)
        return Result.new(outcome: claim.outcome, session: @session) unless
          claim.claimed?

        sent = Transport.perform(
          prepared: claim.prepared, deadline_at: claim.task.deadline_at,
          now: @now, client: @client
        )
        apply(claim.task, sent)
      end

      private

        # A nil outcome is how the apply services spell an unanswered step;
        # the status word they record is the client's own — the HTTP status
        # it answered with, or its error class when it did not.
        def apply(task, sent)
          normalized = sent.responded? ? normalize(task, sent) : nil
          applied = applier(task).call(
            session: @session, task: task, outcome: normalized,
            normalized_status: status_word(sent), now: @now
          )
          Result.new(outcome: applied.outcome, session: applied.session, task: task)
        end

        # Bounded at the task column's width; a class name is never longer.
        def status_word(sent)
          return "http_#{sent.status}" if sent.responded?

          sent.reason.first(ModelProviderOAuthTask::NORMALIZED_STATUS_LIMIT)
        end

        def applier(task)
          case task.exchange_kind
          when "code_exchange", "token_refresh" then InstallCredential
          else ApplyDeviceStart
          end
        end

        def normalize(task, sent)
          Responses.public_send(
            task.exchange_kind == "user_code_request" ? :user_code : task.exchange_kind,
            status: sent.status, body: sent.body
          )
        end
    end
  end
end
