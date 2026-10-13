module Rho
  module IngressTelegram
    module Locales
      ENGLISH = {
        "destination_unavailable" => "The destination Bot has no available Telegram connection and admitted chat/topic binding. Its result was not sent there.",
        "destination_copy" => "This result was delivered from another Bot. Continue or control the task in its source chat/topic; send a new message for a separate request here.",
        "external_explicit_only" => "This Bot responds to direct messages, mentions and replies. Passive observation and active group participation are not available.",
        "identity_in_use" => "telegram: this Telegram bot is already configured for another Agent",
        "agent_uuid_required" => "agent_public_id must be an Agent UUID",
        "bot_unavailable" => "Choose an editable bot from this rho instance.",
        "home_required" => "This bot needs a home workspace. Choose one on its Telegram page, then use /new.",
        "home_managed" => "This bot's home workspace is managed on its Telegram page. Use /new after changing it; saved sessions keep their workspace.",
        "owner_only" => "This bot accepts private messages only from its configured owner. Manage the owner on its Telegram settings page.",
        "bot_code_mode" => "Bots do not use Code Mode. Manage Subagent in the Bot settings; turn it off to do the work directly in this conversation.",
        "owner_discovery" => "Your Telegram user ID is %{id}. Configure this ID as the bot owner on its Telegram settings page.",
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
