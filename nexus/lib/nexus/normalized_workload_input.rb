module Nexus
  # Normalized content plus the exact ordered, creator-scoped uploads accepted
  # with it; `ModelRequests::Build` lowers its request from this shape.
  NormalizedWorkloadInput = Data.define(:value, :uploads)
end
