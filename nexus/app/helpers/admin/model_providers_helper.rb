module Admin::ModelProvidersHelper
  PROVIDER_NAMES = {
    "openai_api" => "OpenAI", "anthropic" => "Anthropic", "gemini" => "Google Gemini",
    "codex_subscription" => "OpenAI Codex", "openrouter" => "OpenRouter",
    "deepseek" => "DeepSeek", "xai" => "xAI",
  }.freeze

  def model_provider_name(id, display_name: nil)
    display_name.presence || PROVIDER_NAMES.fetch(id) { id.humanize }
  end

  PROTOCOL_NAMES = {
    "openai_compatible_chat" => "OpenAI-compatible Chat", "openai_responses" => "OpenAI Responses",
    "anthropic_messages" => "Anthropic Messages", "gemini_generate_content" => "Google Gemini",
    "openrouter_chat" => "OpenRouter Chat", "deepseek_responses" => "DeepSeek Responses",
    "xai_responses" => "xAI Responses", "openai_images" => "OpenAI Images",
    "openai_audio_speech" => "OpenAI Text to speech", "openai_audio_transcriptions" => "OpenAI Speech to text",
    "openai_embeddings" => "OpenAI Embeddings", "gemini_embeddings" => "Gemini Embeddings",
    "codex_responses" => "Codex Responses",
  }.freeze

  def provider_protocol_options(current: nil)
    formats = SimpleInference::ApiFormat::FORMATS - ["codex_responses"]
    formats << "codex_responses" if current == "codex_responses"
    formats.map { |format| [PROTOCOL_NAMES.fetch(format) { format.humanize }, format] }
  end

  def model_rate_label(key)
    {
      "input_per_mtok" => "Input per 1M tokens", "output_per_mtok" => "Output per 1M tokens",
      "cached_input_per_mtok" => "Cached input per 1M tokens", "cache_write_per_mtok" => "Cache write per 1M tokens",
      "cache_write_1h_per_mtok" => "1-hour cache write per 1M tokens", "input_cache_hit_per_mtok" => "Cache hit per 1M tokens",
      "input_cache_miss_per_mtok" => "Cache miss per 1M tokens", "per_image" => "Per image",
      "per_mchar" => "Per 1M characters", "per_minute" => "Per audio minute",
      "long_context_threshold_tokens" => "Long context threshold (tokens)",
      "long_context_input_multiplier" => "Long context input multiplier",
      "long_context_output_multiplier" => "Long context output multiplier",
    }.fetch(key) { key.humanize.sub("per mtok", "per 1M tokens") }
  end

  def provider_choice_classes(selected:)
    class_names("inline-flex items-center justify-center rounded-full border px-3 py-1.5 text-xs font-medium focus-visible:outline-2 focus-visible:outline-offset-2",
      selected ? "border-base-content bg-base-content text-base-100" : "border-transparent text-base-content/60 hover:bg-base-300 hover:text-base-content")
  end

  def provider_credential_label(provider)
    if provider.fetch(:reauthorization_required)
      "Sign-in required"
    elsif provider.fetch(:credentials) == "none"
      "No credentials needed"
    elsif provider.fetch(:configured)
      provider.fetch(:credentials) == "api_key" ? "API key saved" : "Subscription connected"
    else
      provider.fetch(:credentials) == "api_key" ? "API key needed" : "Not connected"
    end
  end

  def provider_credentials_path(provider)
    if provider.fetch(:credentials) == "oauth_tokens"
      admin_model_provider_authorization_path(provider.fetch(:id))
    else
      admin_model_provider_api_key_path(provider.fetch(:id))
    end
  end

  def model_discovery_message(outcome)
    case outcome
    when :stale then "These settings changed while the directory was being fetched. Fetch again to update model availability."
    when :invalid then "The directory was fetched, but model availability could not be saved. Review the provider's model configuration."
    when :unsupported_protocol then "This provider does not support model discovery. Enter a model ID manually."
    when :missing_credential then "Save usable credentials before fetching the directory, or enter a model ID manually."
    else "The provider's model directory could not be fetched. It may be unavailable or unsupported. Try again or enter a model ID manually."
    end
  end

  def model_connection_test_message(outcome)
    {
      succeeded: "Connection succeeded. The model accepted the test request.",
      model_not_found: "The provider reports that this model no longer exists or is no longer served.",
      not_found: "This model is no longer configured. Return to model settings.",
      provider_disabled: "Enable this provider before testing its connection.",
      missing_credential: "Save the provider's credentials before testing.",
      reauthorization_required: "Sign in to the provider again before testing.",
      credential_unusable: "The provider credential is not ready. Reconnect and try again.",
      model_plane_unavailable: "The model catalog is currently unavailable.",
      test_input_unavailable: "This model needs additional workload settings before a connection test can run.",
      request_invalid: "The configured model cannot accept this test. Review its protocol and capabilities.",
      authentication_failed: "The provider rejected authentication or access. Check credentials and model permissions.",
      quota_exceeded: "The provider rejected this request because of billing or quota limits.",
      rate_limited: "The provider rate-limited this request. Try again later.",
      provider_error: "The provider could not complete the test. Check its service status and model configuration.",
      timed_out: "The test timed out. The model has not been marked invalid.",
      connection_failed: "Could not connect to the provider. Check the saved endpoint and network.",
      invalid_response: "The provider returned a response this protocol could not read.",
      request_rejected: "The provider declined the test request.",
    }.fetch(outcome)
  end

  def model_pricing_label(pricing)
    case pricing.fetch(:state)
    when "priced"
      input, output = pricing[:input_per_mtok], pricing[:output_per_mtok]
      if input && output
        "#{pricing.fetch(:unit)} #{input} input / #{output} output per 1M tokens"
      else
        "Estimated usage cost in #{pricing.fetch(:unit)}"
      end
    when "unmetered" then "No cost estimate configured. Recorded usage is still tracked."
    when "known_free_candidate" then "No usage cost in the configured catalog"
    else "Cost estimate unavailable. Recorded usage is still tracked."
    end
  end

  def provider_authorization_label(authorization)
    authorization.fetch(:state) == "authorized" ? "Subscription connected" : "No subscription connected"
  end

  def latest_provider_sign_in_completed?(authorization, session)
    session && session.fetch(:state) == "completed" &&
      authorization[:session]&.fetch(:public_id) == session.fetch(:public_id)
  end

  def provider_sign_in_description(session)
    case session.fetch(:state)
    when "pending"
      if session.fetch(:kind) == "token_refresh"
        "Nexus is renewing the connection. No action is needed."
      elsif !session.fetch(:owned_by_current_user)
        "Another administrator started this sign-in. Only that administrator can see its authorization code."
      elsif session.fetch(:progress) == "exchanging_code"
        "Sign-in approved. Nexus is finishing the connection."
      elsif session[:user_code].present?
        "Open the authorization page, sign in to your provider account, and enter this code."
      else
        "Preparing sign-in. Your authorization code will appear here shortly."
      end
    when "completed" then "This sign-in finished. The current subscription status is shown above."
    when "expired" then "This sign-in expired."
    when "revoked"
      session.fetch(:outcome) == "superseded" ? "A newer sign-in replaced this one." : "This sign-in was stopped."
    else
      if session.fetch(:outcome) == "device_code_not_enabled"
        "Device sign-in is not enabled for this account. Enable it with your provider before connecting."
      else
        "Sign-in did not complete."
      end
    end
  end
end
