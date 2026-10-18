module ModelProviders
  # A successful operator save connects the provider. Keep the credential
  # primitive independent for deployment imports and lock Policy before Credential.
  class ConfigureAPIKey
    def self.call(account:, provider_id:, api_key:)
      value = api_key.to_s.strip
      return SetAPIKey::Result.new(outcome: :invalid, credential: nil) if value.blank?

      result = nil
      ModelProviderConfig.transaction do
        # Existing enabled lanes need only their switch, not the model overlay.
        # create_or_find_by! locks the concurrent winner inside this transaction.
        policy = ModelProviderConfig.select(:id, :enabled, :lock_version).lock
          .create_or_find_by!(account: account, provider_id: provider_id) do |row|
            row.model_overrides = ModelProviderConfig.empty_overrides
          end
        unless policy.enabled?
          enabled = EnableLane.call(account: account, provider_id: provider_id, expected_lock_version: policy.lock_version)
          unless enabled.done?
            result = SetAPIKey::Result.new(outcome: :invalid, credential: nil)
            raise ActiveRecord::Rollback
          end
        end
        result = SetAPIKey.call(account: account, provider_id: provider_id, api_key: value)
        raise ActiveRecord::Rollback unless result.done?
      end
      result
    end
  end
end
