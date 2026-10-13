module ModelProviders
  module CodexAuthorization
    # The refresh failure taxonomy, copied from codex `manager.rs`
    # (3711943d1): the one place Nexus reads an error body, because a refresh
    # body distinguishes "try later" from "never again" where a poll's does not.
    module RefreshFailures
      # Lowercased before matching, as upstream does. `refresh_token_reused`
      # was not reproducible live but upstream ships it.
      PERMANENT_CODES = ModelProviderOAuthSession::REFRESH_TOKEN_FAILURE_OUTCOMES.to_h do |outcome|
        [outcome, outcome.to_sym]
      end.freeze

      # An unauthorized refresh is permanent whatever the body says: the token
      # was rejected as an identity, and repeating it changes nothing.
      UNAUTHORIZED_STATUS = 401

      class << self
        # Returns the terminal reason, or nil when the failure is transient and
        # the session should simply try again later.
        def classify(status:, body:)
          named = PERMANENT_CODES[error_code(body)]
          return named if named
          return :refresh_rejected if status == UNAUTHORIZED_STATUS

          nil
        end

        # The three places upstream looks, in its order.
        def error_code(body)
          document = ActiveSupport::JSON.decode(body.to_s)
          code = case document
          when Hash then hash_code(document)
          else nil
          end
          code&.to_s&.downcase
        rescue JSON::ParserError
          nil
        end

        private

          def hash_code(document)
            case document["error"]
            when Hash then document.fetch("error")["code"] || document["code"]
            when String then document.fetch("error")
            else document["code"]
            end
          end
      end
    end
  end
end
