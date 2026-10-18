require_relative "support/rho_telegram_case"

# External requests and delegated work retain the admitted capability floor.
class RhoTelegramPermissionsTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramPermissions
end
