class ApplicationController < ActionController::Base
  helper_method :sidebar_nav_partial

  include Authentication
  prepend_before_action :set_return_target_privacy_headers
  # A direct-created member signs in with a conveyed temporary password;
  # until it is changed only the password page and logout are reachable.
  # Controllers on that allowlist skip this action.
  before_action :require_completed_password_change

  include Pagy::Method
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

    # A response carrying a resumable return target must not be cached or leak
    # it through the referrer; broader than the device ceremony because the
    # headers cost nothing and reconstructing the navigation chain did.
    def set_return_target_privacy_headers
      return unless return_to_url

      no_store
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def require_completed_password_change
      if authenticated? && Current.identity&.password_change_required?
        if (return_to = resumable_request_url)
          redirect_to settings_password_path(return_to: return_to), notice: t("sessions.password_change_required")
        else
          redirect_to settings_password_path, notice: t("sessions.password_change_required")
        end
      end
    end

    # The console shell renders one drawer layout with a swappable nav; the
    # admin area overrides this with its back-link variant.
    def sidebar_nav_partial
      "layouts/shared/console_nav"
    end

    # Pagy merges GET and POST by default. Pagination links are navigations,
    # so they carry only the original query string and never form-body data.
    def pagy(paginator = :offset, collection, **options)
      super(
        paginator,
        collection,
        **options,
        request: {
          base_url: request.base_url,
          path: request.path,
          params: request.query_parameters,
          cookie: request.cookies["pagy"],
        }
      )
    end
end
