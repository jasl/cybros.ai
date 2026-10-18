module ModelProviders
  # One rule for both kinds: an install lands only on the exact credential
  # it froze (`expected_lineage_id` + `expected_generation`), so a stale
  # continuation can never overwrite a newer success.
  class InstallOAuthPair
    Result = Data.define(:outcome, :credential) do
      def done? = outcome == :applied
    end

    def self.call(account:, provider_id:, access_token:, refresh_token:, lineage_id:,
      expected_generation:, expires_at:,
      expected_lineage_id: lineage_id, provider_account_identity: nil)
      new(
        account:, provider_id:, access_token:, refresh_token:, lineage_id:,
        expected_lineage_id:, expected_generation:, expires_at:, provider_account_identity:
      ).call
    end

    def initialize(account:, provider_id:, access_token:, refresh_token:, lineage_id:,
      expected_lineage_id:, expected_generation:, expires_at:, provider_account_identity:)
      @account = account
      @provider_id = provider_id
      @access_token = access_token
      @refresh_token = refresh_token
      @lineage_id = lineage_id
      @expected_lineage_id = expected_lineage_id
      @expected_generation = expected_generation
      @expires_at = expires_at
      @provider_account_identity = provider_account_identity
    end

    def call
      ModelProviderCredential.transaction do
        credential = ModelProviderCredential.lock.find_by(
          account_id: @account.id, provider_id: @provider_id
        )
        credential ? replace_pair(credential) : create_pair
      end
    end

    private

    # Only an install that froze nothing may create; a named row that is
    # gone is the same staleness as a different one, as is losing the insert race.
    def create_pair
      return Result.new(outcome: :stale, credential: nil) unless @expected_generation.nil?

      credential = ModelProviderCredential.create_or_find_by(account: @account, provider_id: @provider_id) do |row|
        row.assign_attributes(
          material_kind: "oauth_tokens",
          secret: @access_token, refresh_secret: @refresh_token,
          provider_account_identity: @provider_account_identity,
          authorization_lineage_id: @lineage_id, refreshed_at: Time.current,
          expires_at: @expires_at
        )
      end
      if !credential.persisted?
        Result.new(outcome: :invalid, credential: nil)
      elsif credential.previously_new_record?
        Result.new(outcome: :applied, credential: credential)
      else
        replace_pair(credential)
      end
    end

    # The row must be exactly the one this install froze. A device start then
    # writes its OWN lineage over it (it is minting, not continuing); a
    # refresh froze that same lineage, so writing it back is a no-op.
    def replace_pair(credential)
      unless credential.material_kind == "oauth_tokens"
        return Result.new(outcome: :material_kind_conflict, credential: nil)
      end
      unless credential.authorization_lineage_id == @expected_lineage_id &&
          credential.generation == @expected_generation
        return Result.new(outcome: :stale, credential: nil)
      end

      credential.update!(
        secret: @access_token, refresh_secret: @refresh_token,
        provider_account_identity: @provider_account_identity || credential.provider_account_identity,
        authorization_lineage_id: @lineage_id,
        generation: credential.generation + 1, refreshed_at: Time.current,
        expires_at: @expires_at,
        reauthorization_required: false, reauthorization_reason: nil
      )
      Result.new(outcome: :applied, credential: credential)
    end
  end
end
