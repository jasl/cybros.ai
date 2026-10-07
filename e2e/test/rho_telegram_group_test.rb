require_relative "support/rho_telegram_case"
require_relative "support/rho_memory_policy"

# Group observation, memory and authority share setup without inheriting another suite.
class RhoTelegramGroupTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramGroups
  include E2E::RhoTelegramMemory
  include E2E::RhoMemoryPolicy
  include E2E::RhoTelegramPermissions
  include E2E::RhoTelegramParticipation
end
