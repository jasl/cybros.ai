module ModelProviders
  # Deletes only a lane's stored OAuth pair; this operation performs no
  # provider IO.
  class ClearOAuth
    Result = Data.define(:outcome) do
      def done? = outcome == :applied
    end

    def self.call(account:, provider_id:)
      ModelProviderCredential.transaction do
        credential = ModelProviderCredential.lock.find_by(account_id: account.id, provider_id: provider_id)
        case credential
        when nil
          Result.new(outcome: :not_found)
        else
          next Result.new(outcome: :material_kind_conflict) unless credential.material_kind == "oauth_tokens"

          credential.destroy!
          Result.new(outcome: :applied)
        end
      end
    end
  end
end
