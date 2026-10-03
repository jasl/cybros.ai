module E2E
  module Manual
    module CodexAuthorization
      # The development door: CODEX_AUTH_FILE is a seed, not a source of truth;
      # device start stays the only production path. Refuses outside
      # development/test, no HTTP door, never logs a token.
      class DevImport
        class << self
          def call(account:, path: ENV["CODEX_AUTH_FILE"], now: Time.current)
            new(account, path, now).call
          end
        end

        def initialize(account, path, now)
          @account = account
          @path = path.to_s
          @now = now
        end

        def call
          # test admitted deliberately (the service's own unit tests run
          # there); production refuses here AND at the rake guard.
          return refused(:not_development) unless Rails.env.development? || Rails.env.test?
          return refused(:no_auth_file) if @path.blank? || !File.exist?(expanded_path)
          # Importing over a pending session's frozen triple would strand it
          # unclaimable — AcceptSession's one-nonterminal rule.
          if ModelProviderOAuthSession.nonterminal
              .exists?(account_id: @account.id, provider_id: "codex_subscription")
            return refused(:oauth_session_in_progress)
          end

          tokens = parsed_tokens
          return refused(:malformed_auth_file) if tokens.nil?

          current = ModelProviderCredential.find_by(account_id: @account.id, provider_id: "codex_subscription")
          installed = ModelProviders::InstallOAuthPair.call(
            account: @account,
            provider_id: "codex_subscription",
            access_token: tokens.fetch("access_token"),
            refresh_token: tokens.fetch("refresh_token"),
            lineage_id: SecureRandom.uuid,
            expected_lineage_id: current&.authorization_lineage_id,
            expected_generation: current&.generation,
            expires_at: token_expiry(tokens.fetch("access_token")),
            provider_account_identity: tokens["account_id"].presence
          )
          return refused(installed.outcome) unless installed.done?

          ModelProviders::CodexAuthorization::Result.new(outcome: :imported, credential: installed.credential)
        end

        private

          def refused(outcome) = ModelProviders::CodexAuthorization::Result.new(outcome: outcome)

          def expanded_path = File.expand_path(@path)

          def parsed_tokens
            parsed = Hash.try_convert(JSON.parse(File.read(expanded_path)))
            tokens = parsed && Hash.try_convert(parsed["tokens"])
            return nil if tokens.nil?
            return nil if tokens["access_token"].blank? || tokens["refresh_token"].blank?

            tokens
          rescue JSON::ParserError, SystemCallError
            nil
          end

          # An unparsable token imports with a short window: refusing a
          # working seed over a cosmetic parse would be the worse failure.
          def token_expiry(access_token)
            payload = access_token.split(".")[1].to_s
            padded = payload + ("=" * ((4 - payload.length % 4) % 4))
            claims = Hash.try_convert(
              ActiveSupport::JSON.decode(Base64.urlsafe_decode64(padded))
            )
            exp = claims ? claims["exp"].to_i : 0
            exp.positive? ? Time.zone.at(exp) : @now + 15.minutes
          rescue ArgumentError, JSON::ParserError
            @now + 15.minutes
          end
      end
    end
  end
end
