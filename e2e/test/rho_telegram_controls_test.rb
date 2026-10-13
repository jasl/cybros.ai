require_relative "support/rho_telegram_case"

# Commands, queue edits and resume share the ordinary Telegram control surface.
class RhoTelegramControlsTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramCommands
  include E2E::RhoTelegramControls
end
