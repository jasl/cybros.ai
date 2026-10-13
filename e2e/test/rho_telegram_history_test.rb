require_relative "support/rho_telegram_case"

# History operations preserve the source route and accepted task identities.
class RhoTelegramHistoryTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramHistory
end
