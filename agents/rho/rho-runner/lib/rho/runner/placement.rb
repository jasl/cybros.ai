module Rho
  class Runner
    # ONE CONVERSATION'S PLACEMENT: the frozen `ToolEnv`
    # its tools execute against, the toolset built over it — the same tool
    # classes, byte-identical to the model, differing from every other
    # placement in the env alone — and the resolved record (`Environment::
    # Binding`), nil at placement ZERO: the runner's default root, where a
    # standalone loop, a binding nobody wrote and a root this host does not
    # have all land.
    #
    # A VALUE: `Toolsets` memoizes the env and the toolset per ROOT SET and
    # answers a fresh one of these per claim with the claim's own record,
    # so two conversations on one root share one env object and still each
    # carry their own anchor.
    Placement = Data.define(:env, :toolset, :binding)
  end
end
