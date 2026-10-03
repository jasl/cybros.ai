module Nexus
  # The one shape a compaction policy takes, on a round or on a profile:
  # `kernel` repairs an overflow with the kernel's summarizer, `delegate`
  # arms the agent's named tool, `off` keeps the typed refusal.
  module CompactionPolicy
    MODES = %w[kernel delegate off].freeze

    # A delegated repair with no tool to call is a policy that cannot run,
    # and it would not be discovered until the round that needed it had failed.
    def self.well_formed?(value)
      policy = Hash.try_convert(value)
      return false if policy.nil?

      mode = policy["mode"].to_s
      MODES.include?(mode) && (mode != "delegate" || !policy["tool_name"].to_s.empty?)
    end
  end
end
