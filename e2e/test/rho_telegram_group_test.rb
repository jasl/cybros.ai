require_relative "support/rho_telegram_case"

# Group observation and controls share one conversation with per-input attribution.
class RhoTelegramGroupTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramGroups
end
