module ModelProviders
  module CodexAuthorization
    # Puts the bytes on the wire with no lock held and reports the HTTP
    # client's verdict, consumed once: it answered, or it did not and its own
    # word for why is the record. What to do after an unanswered step is the
    # flow's definition (Claim), never a proof derived here.
    module Transport
      # A wire fact, not a step result: the response, or the client's own
      # word for the failure (its error class, or the claim's deadline).
      Delivery = Data.define(:status, :body, :reason) do
        def responded? = reason.nil?
      end

      class << self
        # `deadline_at` is the claim's own absolute deadline, so the request
        # cannot outlive the record that authorized it.
        def perform(prepared:, deadline_at:, now: Time.current, client: nil)
          remaining = deadline_at - now
          return failed(InstallCredential::LATE_STATUS) if remaining <= 0

          response = (client || default_client(remaining))
            .post(prepared.url, headers: prepared.headers, body: prepared.body)
          # HTTPX also wraps received 4xx/5xx responses as HTTPError. Their
          # status/body belong to the protocol (including a pending 403 poll),
          # while a transport error means no complete response was received.
          error = response.error
          return responded(response) if error.nil? || (error in HTTPX::HTTPError)

          failed(error.class.name)
        rescue StandardError => error
          failed(error.class.name)
        end

        private

          def default_client(remaining)
            HTTPX.with(
              timeout: {
                connect_timeout: remaining.clamp(..10),
                request_timeout: remaining,
                operation_timeout: remaining,
              }
            )
          end

          def responded(response)
            Delivery.new(status: response.status, body: response.body.to_s, reason: nil).freeze
          end

          def failed(reason) = Delivery.new(status: nil, body: nil, reason: reason).freeze
      end
    end
  end
end
