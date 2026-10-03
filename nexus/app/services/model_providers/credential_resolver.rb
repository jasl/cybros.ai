module ModelProviders
  # Typed credential resolution for one lane: enabled, present, matching
  # the profile's credential lane, unmarked, inside the usable horizon.
  # Refusals precede any secret access; inspection never renders material.
  class CredentialResolver
    Result = Data.define(:outcome, :credential) do
      def resolved? = outcome == :resolved

      def inspect
        "#<ModelProviders::CredentialResolver::Result outcome=#{outcome}>"
      end
      alias_method :to_s, :inspect
    end

    class << self
      def resolve(account:, provider_id:, credential_lane:, total_execution_deadline_seconds:, now:)
        unless ModelProviderPolicy.exists?(account_id: account.id, provider_id: provider_id, enabled: true)
          return refusal(:lane_disabled)
        end

        # A credentialless endpoint still needs an enabled lane. Its profile
        # requests no authentication material, so no credential row is read.
        return Result.new(outcome: :resolved, credential: nil) if credential_lane == "none"

        credential = ModelProviderCredential.find_by(account_id: account.id, provider_id: provider_id)
        return refusal(:no_credential) if credential.nil?
        return refusal(:credential_kind_mismatch) unless credential.material_kind == credential_lane
        return refusal(:reauthorization_required) if credential.reauthorization_required?

        usable = credential.usable_for?(
          total_execution_deadline_seconds: total_execution_deadline_seconds, now: now
        )
        return refusal(:credential_unusable) unless usable

        Result.new(outcome: :resolved, credential: credential)
      end

      private

      def refusal(outcome)
        Result.new(outcome: outcome, credential: nil)
      end
    end
  end
end
