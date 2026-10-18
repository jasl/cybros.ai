module Admin::ModelProvidersHelper
  def model_provider_name(id, display_name: nil)
    display_name.presence || t("helpers.model_providers.names").fetch(id.to_sym) { id.humanize }
  end

  def provider_protocol_options(current: nil)
    formats = SimpleInference::ApiFormat::FORMATS - ["codex_responses"]
    formats << "codex_responses" if current == "codex_responses"
    formats.map { |format| [t("helpers.model_providers.protocols").fetch(format.to_sym) { format.humanize }, format] }
  end

  def model_rate_label(key)
    t("helpers.model_providers.rates").fetch(key.to_sym) { key.humanize }
  end

  def provider_choice_classes(selected:)
    class_names("inline-flex items-center justify-center rounded-full border px-3 py-1.5 text-xs font-medium focus-visible:outline-2 focus-visible:outline-offset-2",
      selected ? "border-base-content bg-base-content text-base-100" : "border-transparent text-base-content/60 hover:bg-base-300 hover:text-base-content")
  end

  def provider_credential_label(provider)
    if provider.fetch(:reauthorization_required)
      t("helpers.model_providers.credentials.sign_in_required")
    elsif provider.fetch(:credentials) == "none"
      t("helpers.model_providers.credentials.not_required")
    elsif provider.fetch(:configured)
      provider.fetch(:credentials) == "api_key" ? t("helpers.model_providers.credentials.api_key_saved") : t("helpers.model_providers.subscription.connected")
    else
      provider.fetch(:credentials) == "api_key" ? t("helpers.model_providers.credentials.api_key_needed") : t("helpers.model_providers.credentials.not_connected")
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
    when :stale then t("helpers.model_providers.discovery.stale")
    when :invalid then t("helpers.model_providers.discovery.invalid")
    when :unsupported_protocol then t("helpers.model_providers.discovery.unsupported_protocol")
    when :missing_credential then t("helpers.model_providers.discovery.missing_credential")
    else t("helpers.model_providers.discovery.unavailable")
    end
  end

  def model_connection_test_message(outcome)
    t("helpers.model_providers.connection_test").fetch(outcome)
  end

  def model_pricing_label(pricing)
    case pricing.fetch(:state)
    when "priced"
      input, output = pricing[:input_per_mtok], pricing[:output_per_mtok]
      if input && output
        t("helpers.model_providers.pricing.token_rates", unit: pricing.fetch(:unit), input:, output:)
      else
        t("helpers.model_providers.pricing.estimated_cost", unit: pricing.fetch(:unit))
      end
    when "unmetered" then t("helpers.model_providers.pricing.unmetered")
    when "known_free_candidate" then t("helpers.model_providers.pricing.known_free")
    else t("helpers.model_providers.pricing.unavailable")
    end
  end

  def provider_authorization_label(authorization)
    authorization.fetch(:state) == "authorized" ? t("helpers.model_providers.subscription.connected") : t("helpers.model_providers.subscription.not_connected")
  end

  def latest_provider_sign_in_completed?(authorization, session)
    session && session.fetch(:state) == "completed" &&
      authorization[:session]&.fetch(:public_id) == session.fetch(:public_id)
  end

  def provider_sign_in_description(session)
    case session.fetch(:state)
    when "pending"
      if session.fetch(:kind) == "token_refresh"
        t("helpers.model_providers.sign_in.renewing", brand: t("brand.name"))
      elsif !session.fetch(:owned_by_current_user)
        t("helpers.model_providers.sign_in.waiting_for_owner")
      elsif session.fetch(:progress) == "exchanging_code"
        t("helpers.model_providers.sign_in.exchanging_code", brand: t("brand.name"))
      elsif session[:user_code].present?
        t("helpers.model_providers.sign_in.enter_code")
      else
        t("helpers.model_providers.sign_in.preparing")
      end
    when "completed" then t("helpers.model_providers.sign_in.completed")
    when "expired" then t("helpers.model_providers.sign_in.expired")
    when "revoked"
      session.fetch(:outcome) == "superseded" ? t("helpers.model_providers.sign_in.superseded") : t("helpers.model_providers.sign_in.revoked")
    else
      if session.fetch(:outcome) == "device_code_not_enabled"
        t("helpers.model_providers.sign_in.device_code_not_enabled")
      else
        t("helpers.model_providers.sign_in.failed")
      end
    end
  end
end
