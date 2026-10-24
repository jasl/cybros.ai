require_relative "support/rho_telegram_case"

# Active participation uses observation history and keeps confirmed replies durable.
class RhoTelegramParticipationTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramPermissions::Helpers
  include E2E::RhoTelegramParticipation
end
