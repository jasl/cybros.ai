# The kernel's own limits struct from its two window bounds alone — the
# advisory member is `effective_input_tokens`, the hard one `input_tokens`
# — so an assembly test never ducks the struct and every bound derived on
# it (`planning_input_bound`) is the one production reads.
module LimitsOf
  module_function

  def bounds(advisory: nil, hard: nil)
    Nexus::ModelCapabilityLimits.from_h(
      Nexus::ModelCapabilityLimits.members.index_with(nil)
        .merge(effective_input_tokens: advisory, input_tokens: hard)
    )
  end
end
