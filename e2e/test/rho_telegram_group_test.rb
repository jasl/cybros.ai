require_relative "support/rho_telegram_case"

# Group observation and controls share one conversation with per-input attribution.
class RhoTelegramGroupTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramGroups

  private

    def telegram_bot_targets
      # The participant's private Bot remains a competing destination for the
      # no-private-reply assertions; these cases never use the owner's private Bot.
      super.except("101:0")
    end
end
