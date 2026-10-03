module ModelProviders
  # Disables a provider lane in place; the anchor row is retained so
  # later changes retain the same policy-row lock.
  class DisableLane < PolicyCommand
    private

    def mutate(policy)
      result = super
      if result.done?
        ModelProviderOAuthSession.revoke_for_provider(
          account: @account, provider_id: @provider_id, reason: "provider_disabled"
        )
      end
      result
    end

    def apply_change(candidate)
      candidate.enabled = false
    end
  end
end
