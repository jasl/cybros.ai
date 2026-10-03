module ModelProviders
  # A changed secret advances the credential's generation; the same
  # normalized material is a no-op. Never touches an oauth_tokens row.
  class SetAPIKey
    Result = Data.define(:outcome, :credential) do
      def done? = %i[applied noop].include?(outcome)
    end

    def self.call(account:, provider_id:, api_key:)
      value = api_key.to_s.strip
      return Result.new(outcome: :invalid, credential: nil) if value.blank?

      credential = ModelProviderCredential.create_or_find_by!(account: account, provider_id: provider_id) do |row|
        row.material_kind = "api_key"
        row.secret = value
      end
      return Result.new(outcome: :applied, credential: credential) if credential.previously_new_record?

      credential.with_lock do
        unless credential.material_kind == "api_key"
          next Result.new(outcome: :material_kind_conflict, credential: nil)
        end
        next Result.new(outcome: :noop, credential: credential) if credential.secret == value

        credential.update!(
          secret: value, generation: credential.generation + 1, rotated_at: Time.current
        )
        Result.new(outcome: :applied, credential: credential)
      end
    end
  end
end
