module ModelProviders
  # Imports API keys from the environment, including values loaded by dotenv.
  # Everything except environment-variable names comes from the catalog:
  # undeclared providers are skipped because no lane could use their keys.
  class ImportEnvironmentCredentials
    # API-key seeding excludes Codex OAuth material, which is managed through
    # its own authorization flow.
    ENV_KEYS = {
      "openai_api" => "OPENAI_API_KEY",
      "anthropic" => "ANTHROPIC_API_KEY",
      "gemini" => "GEMINI_API_KEY",
      "deepseek" => "DEEPSEEK_API_KEY",
      "xai" => "XAI_API_KEY",
      "openrouter" => "OPENROUTER_API_KEY",
    }.freeze

    Result = Data.define(:outcomes)

    def self.call(account:, env: ENV) = new(account: account, env: env).call

    def initialize(account:, env:)
      @account = account
      @env = env
    end

    def call
      declared = ModelCatalog.current.providers.keys

      Result.new(outcomes: ENV_KEYS.to_h { |provider_id, env_key|
        [provider_id, import(provider_id, env_key, declared)]
      })
    end

    private

      # Removing a key from the environment leaves its credential and lane
      # unchanged. Explicit revocation belongs to RemoveAPIKey.
      def import(provider_id, env_key, declared)
        return :undeclared unless declared.include?(provider_id)

        api_key = @env[env_key].to_s.strip
        return :absent if api_key.empty?

        credential = SetAPIKey.call(
          account: @account, provider_id: provider_id, api_key: api_key
        )
        # Refuse before enabling the lane, without exposing the key material.
        raise "#{provider_id} credential refused (#{credential.outcome})" unless credential.done?

        enable(provider_id)
        credential.outcome
      end

      # An existing policy carries the operator's decision. Only a missing
      # policy is created enabled; re-seeding never re-enables a disabled lane.
      def enable(provider_id)
        return if ModelProviderPolicy.exists?(account_id: @account.id, provider_id: provider_id)

        lane = EnableLane.call(
          account: @account, provider_id: provider_id, expected_lock_version: nil
        )
        raise "#{provider_id} lane refused (#{lane.outcome})" unless lane.done?
      end
  end
end
