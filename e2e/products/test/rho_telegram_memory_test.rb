require_relative "support/rho_telegram_case"

# Memory follows the Bot, conversation and requesting Speaker.
class RhoTelegramMemoryTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramMemory
end
