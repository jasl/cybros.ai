module ModelProviders
  # An untouched catalog lane gets its anchor on first enable.
  class EnableLane < PolicyCommand
    private

    def create_row
      create_policy(enabled: true)
    end

    def apply_change(policy)
      policy.enabled = true
    end
  end
end
