module Rho
  module IngressTelegram
    module Locales
      ENGLISH = {
        "settings_integers_required" => "telegram: owner_id, stale_after and input_debounce_seconds must be integers",
        "input_debounce_invalid" => "telegram: input_debounce_seconds must be an integer from 0 to 10",
        "input_admission_limit" => "Too many messages are waiting for admission. Please try again later.",
        "input_admission_started" => "Message admission has started. Check /queue or /status before stopping this task.",
        "input_recovery_expired" => "The previous request may already have been accepted. Its recovery window expired; check /queue or /history before sending it again.",
        "input_not_accepted" => "Message not accepted: %{reason}.",
        "input_state_incompatible" => "Telegram has unfinished input admission from an older version. Finish that queue with the previous version before upgrading; do not delete the Telegram state.",
      }.freeze
    end
  end
end
