module SsoCallbackAddress
  private

    def sso_provider_callback_url(provider)
      options = Rails.application.routes.default_url_options
      if Rails.env.production?
        return unless options[:protocol] == "https" && options[:host].present?
      end
      sso_callback_url(provider.public_id, **options)
    end
end
