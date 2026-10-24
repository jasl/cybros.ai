require_relative "support/rho_telegram_case"

# Steering and stop commands keep the exact execution as their target.
class RhoTelegramCommandsTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramCommands
end
