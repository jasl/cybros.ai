module ModelProviders
  # An untouched catalog lane gets its anchor on first enable.
  class EnableLane < ConfigCommand
    private

    def create_row
      create_policy(enabled: true)
    end

    def apply_change(policy)
      policy.enabled = true
      RetainCatalog.capture(policy)
    end
  end
end
