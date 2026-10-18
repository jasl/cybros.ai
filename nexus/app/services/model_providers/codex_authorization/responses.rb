module ModelProviders
  module CodexAuthorization
    # Pure response normalization: status plus bytes in, a typed disposition
    # out. Phase is part of it — the same 404 is terminal on the user-code
    # endpoint and pending on the poll — so there is no phase-agnostic entry point.
    module Responses
      # A wire fact, not a step result: how a provider response reads.
      Disposition = Data.define(:disposition, :facts, :error) do
        def ok? = disposition == :ok
        def pending? = disposition == :pending
        # Distinct from `pending`: the protocol saying wait is not the
        # service failing in a way that says nothing about the token.
        def retryable? = disposition == :retryable
        def terminal? = disposition == :terminal
      end

      # Raised inside this module only, to carry the terminal reason out of a
      # nested read without threading a result through every helper.
      class Unusable < StandardError
        attr_reader :reason

        def initialize(reason)
          @reason = reason
          super(reason.to_s)
        end
      end

      POLL_PENDING_STATUSES = [403, 404].freeze
      TOKEN_FIELDS = %w[id_token access_token refresh_token].freeze
      GRANT_FIELDS = %w[authorization_code code_challenge code_verifier].freeze
      USER_CODE_FIELDS = %w[device_auth_id user_code].freeze

      class << self
        def user_code(status:, body:)
          # Terminal and specific: the operator needs to know the server has the
          # feature off, not that "something 404'd".
          return terminal(:device_code_not_enabled) if status == 404
          return terminal(:provider_error) unless success?(status)

          decoded = decode(body)
          # Upstream accepts the alias; a response that used it is not
          # malformed, it is the same fact under another name.
          named = decoded.merge("user_code" => decoded["user_code"] || decoded["usercode"])

          ok(collect(named, USER_CODE_FIELDS)
            .merge("interval_seconds" => canonical_interval(decoded["interval"])))
        rescue Unusable => error
          terminal(error.reason)
        end

        def device_token_poll(status:, body:)
          return pending if POLL_PENDING_STATUSES.include?(status)
          return terminal(:provider_error) unless success?(status)

          # A 200 installs no credential: it yields a single-use grant that only
          # the separate code exchange can spend.
          ok(collect(decode(body), GRANT_FIELDS))
        rescue Unusable => error
          terminal(error.reason)
        end

        def code_exchange(status:, body:) = token_response(status: status, body: body)

        # The same completeness rule as the exchange: a partial refresh must
        # terminalize rather than install half a credential.
        def token_refresh(status:, body:)
          return token_response(status: status, body: body) if success?(status)

          # Only "this token will never work again" may spend a human's
          # attention; a transient failure is `retryable`.
          reason = RefreshFailures.classify(status: status, body: body)
          reason ? terminal(reason) : retryable
        end

        private

          def token_response(status:, body:)
            return terminal(:provider_error) unless success?(status)

            document = decode(body)
            ok(collect(document, TOKEN_FIELDS).merge(
              # Required: Nexus never guesses a default TTL. Kept as the
              # issuer's relative seconds; the install converts it.
              "expires_in_seconds" => lifetime(document["expires_in"])
            ))
          rescue Unusable => error
            terminal(error.reason)
          end

          # A JSON number, unlike the poll interval's string. Bounded well
          # under a year: an implausible lifetime is a parse to distrust.
          def lifetime(value)
            seconds = case value
            when Integer then value
            else raise Unusable, :unusable_expiry
            end
            raise Unusable, :unusable_expiry unless seconds.positive? && seconds <= 31_536_000

            seconds
          end

          # The status comes from our own transport, not from the provider.
          def success?(status) = status.between?(200, 299)

          # Oversized and malformed are separate answers because they send an
          # operator to different places: one is a body we refused to read, the
          # other is a body we read and could not understand.
          def decode(body)
            text = body.to_s
            raise Unusable, :oversized_response if
              text.bytesize > Nexus::SizeBounds.fetch(:oauth_exchange_response_bound)

            document = begin
              ActiveSupport::JSON.decode(text)
            rescue JSON::ParserError
              nil
            end
            case document
            when Hash then document
            else raise Unusable, :malformed_response
            end
          end

          def collect(document, fields)
            fields.to_h { |field| [field, bounded(document[field], field)] }.freeze
          end

          # A present-but-oversized field is not the same finding as an absent
          # one, so it raises its own reason rather than reporting as missing.
          def bounded(value, field)
            text = case value
            when String then value.strip
            else raise Unusable, :incomplete_response
            end
            raise Unusable, :incomplete_response if text.empty?
            raise Unusable, :oversized_field if
              text.bytesize > Nexus::SizeBounds.fetch(:oauth_exchange_field_bound)

            text
          end

          # A string upstream. Only canonical decimal seconds in the reviewed
          # range; a JSON number is a terminal protocol error, not a value to coerce.
          def canonical_interval(value)
            digits = case value
            when String then value
            else raise Unusable, :unsupported_poll_interval
            end
            raise Unusable, :unsupported_poll_interval unless digits.match?(CANONICAL_INTERVAL)

            seconds = Integer(digits, 10)
            raise Unusable, :unsupported_poll_interval unless
              ModelProviderOAuthSession::POLL_INTERVAL_SECONDS.cover?(seconds)

            seconds
          end

          def ok(facts) = Disposition.new(disposition: :ok, facts: facts.freeze, error: nil).freeze
          def pending = Disposition.new(disposition: :pending, facts: nil, error: nil).freeze
          def retryable = Disposition.new(disposition: :retryable, facts: nil, error: nil).freeze
          def terminal(error) = Disposition.new(disposition: :terminal, facts: nil, error: error).freeze
      end
    end
  end
end
