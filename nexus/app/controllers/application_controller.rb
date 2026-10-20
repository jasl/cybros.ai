class ApplicationController < ActionController::Base
  helper_method :sidebar_nav_partial

  include Authentication
  prepend_before_action :prevent_return_target_caching
  # A direct-created member signs in with a conveyed temporary password;
  # until it is changed only the password page and logout are reachable.
  # Controllers on that allowlist skip this action.
  before_action :require_completed_password_change

  include Pagy::Method
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

    # Return targets can carry authorization context through sign-in and the
    # password gate. Keep them out of caches; the configured referrer policy
    # prevents cross-origin disclosure without breaking native form posts.
    def prevent_return_target_caching
      no_store if return_to_url
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
