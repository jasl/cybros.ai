require_relative "support/rho_telegram_case"

# Queue edits and resume keep their original work across restarts.
class RhoTelegramControlsTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramControls
end
