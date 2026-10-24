require_relative "support/rho_telegram_case"

# Media crosses real Core, Nexus and Runner execution before Telegram delivery.
class RhoTelegramMediaTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramMedia
end
