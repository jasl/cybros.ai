module Rho
  # A formal turn outcome published in Nexus. External UI or IM delivery is
  # independent; status includes failed and canceled outcomes as well.
  TurnSettlement = Data.define(:workspace_public_id, :conversation_public_id, :turn_public_id,
    :run_public_id, :status, :model, :memory_context)
end
