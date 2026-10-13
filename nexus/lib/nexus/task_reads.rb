module Nexus
  # Authored models read only named results. Position supplies a dependency,
  # never a read; inherited model history belongs to the kernel compiler.
  module TaskReads
    module_function

    def reads?(verb) = verb == "model"
    def of(verb, results) = reads?(verb) ? Array(results) : []

    # Pure membership; delivery timing remains AgentRuns::Delivery's rule.
    def unread(keys, named:, members:, internal:, retired:)
      keys - named.to_a - members.to_a - internal.to_a - retired.to_a
    end
  end
end
