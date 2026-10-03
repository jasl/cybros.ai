class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM_ADDRESS", "Nexus <no-reply@cybros.ai>")
  layout "mailer"

  # Configured readiness derived from deployment configuration: the test and
  # letter_opener adapters count as configured, while SMTP counts only with
  # both an explicit transport endpoint and a request-free absolute-link
  # origin — which is exactly what a configured canonical origin puts into
  # `routes.default_url_options`. Mailers have no request to derive URLs from.
  # Framework SMTP defaults do not imply capability, and readiness never
  # promises transport success.
  def self.delivery_configured?
    case ActionMailer::Base.delivery_method
    when :smtp
      ENV["SMTP_ADDRESS"].present? &&
        Rails.application.routes.default_url_options.present?
    else true
    end
  end
end
