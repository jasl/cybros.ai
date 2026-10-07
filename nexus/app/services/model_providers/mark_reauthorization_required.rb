module ModelProviders
  # Marks a lane's oauth material as requiring fresh authorization. CAS
  # guarded by the same public lineage/generation pair as installs, so a
  # stale observer cannot mark a newer success; a same-state replay is a no-op.
  class MarkReauthorizationRequired
    Result = Data.define(:outcome, :credential) do
      def done? = %i[applied noop].include?(outcome)
    end

    def self.call(account:, provider_id:, lineage_id:, expected_generation:, reason:)
      ModelProviderCredential.transaction do
        credential = ModelProviderCredential.lock.find_by(
          account_id: account.id, provider_id: provider_id
        )
        case credential
        when nil
          Result.new(outcome: :not_found, credential: nil)
        else
          unless credential.authorization_lineage_id == lineage_id &&
              credential.generation == expected_generation
            next Result.new(outcome: :stale, credential: nil)
          end

          if credential.reauthorization_required?
            next Result.new(outcome: :noop, credential: credential)
          end

          credential.update!(reauthorization_required: true, reauthorization_reason: reason)
          Result.new(outcome: :applied, credential: credential)
        end
      end
    end
  end
end
