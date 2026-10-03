module ModelCatalog
  # One immutable published catalog view. The object itself is the process's
  # current in-memory configuration; a local digest cannot prove which
  # catalog a remote provider is serving.
  Snapshot = Data.define(:providers, :models, :selectors)
end
