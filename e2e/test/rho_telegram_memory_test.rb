require_relative "support/rho_telegram_case"
require_relative "support/rho_memory_policy"

# Memory follows the Bot, conversation and requesting Speaker.
class RhoTelegramMemoryTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramMemory
  include E2E::RhoMemoryPolicy
end
