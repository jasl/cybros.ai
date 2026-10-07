module Authentication
  extend ActiveSupport::Concern

  included do
    # Checking initialization must come first: while no Account exists, only
    # the setup surface is reachable.
    before_action :require_initialization
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(only:, **options)
      skip_before_action :require_authentication, only: only, **options
      before_action :resume_session, only: only, **options
    end

    def require_unauthenticated_access(only:, **options)
      allow_unauthenticated_access(only: only, **options)
      before_action :redirect_authenticated_user, only: only, **options
    end

    def allow_uninitialized_access(only:, **options)
      skip_before_action :require_initialization, only: only, **options
    end
  end

  private

    def authenticated?
      Current.session.present?
    end

    def require_initialization
      redirect_to setup_path if Account.none?
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_usable_session_by_cookie
    end

    # Authentication is read-only: resolve the signed public id, apply the
    # Session validity predicate, and set Current — no activity writes and no
    # row destruction.
    def find_usable_session_by_cookie
      Session.find_usable(cookies.signed[:session_id])
    end

    def request_authentication
      # Only a GET-safe navigation can be resumed by the post-login redirect;
      # a mutation URL would 404 as a GET after signing in. Carrying the
      # target in the login page keeps concurrent browser tabs independent.
      if (return_to = resumable_request_url)
        redirect_to new_session_path(return_to: return_to)
      else
        redirect_to new_session_path
      end
    end

    def redirect_authenticated_user
      redirect_to after_authentication_url if authenticated?
    end

    def after_authentication_url
      return_to_url || root_url
    end

    def return_to_url
      return_path(params.slice(:return_to).permit(:return_to)[:return_to])
    end

    def resumable_request_url
      return request.fullpath if request.get? || request.head?

      # Never replay a mutation: resume the explicit page context or the
      # same-origin referrer (the explicit target covers referrer-suppressing pages).
      return_to_url || return_path(request.referer)
    end

    # `url_from` gives the verdict — a path, or this host, never another
    # (the redirect itself is fenced by `action_on_open_redirect`); an
    # accepted location travels as its path, so a login URL never embeds an
    # origin and a same-host location resumes on THIS origin.
    def return_path(location)
      accepted = url_from(location) or return
      uri = URI(accepted)
      return accepted if uri.host.nil?

      [uri.path, uri.query].compact.join("?").presence
    end

    def start_new_session_for(identity)
      started = Sessions::Start.call(source: identity, user_agent: request.user_agent, ip_address: request.remote_ip)
      adopt_session(started.session)
    end

    # Point this browser at an already-issued Session (login, founding, or
    # the personal password change's replacement Session).
    def adopt_session(session)
      Current.session = session
      cookies.signed[:session_id] = {
        value: session.public_id,
        expires: session.expires_at,
        httponly: true,
        secure: request.ssl?,
        same_site: :lax,
      }
      session
    end

    def terminate_session
      Current.session.destroy
      reset_session
      cookies.delete(:session_id)
    end
end
