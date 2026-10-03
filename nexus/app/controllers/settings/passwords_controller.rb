class Settings::PasswordsController < Settings::BaseController
  skip_before_action :require_completed_password_change, only: %i[ show update ]
  before_action :set_identity

  rate_limit to: 10, within: 3.minutes,
    by: -> { Current.user.public_id },
    scope: "settings/current-password",
    only: :update,
    with: -> { redirect_to settings_password_path(return_to: return_to_url), alert: t("settings.current_password_rate_limited") }

  def show
  end

  def update
    submitted = params.expect(password: [:current_password, :password, :password_confirmation])

    replacement = @identity.change_password(
      current_password: submitted[:current_password].to_s,
      password: submitted[:password].to_s,
      password_confirmation: submitted[:password_confirmation].to_s,
      presented_session: Current.session,
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    )

    if replacement
      # The presented Session was consumed; this browser adopts its replacement,
      # while every other earlier Session is fenced by its stale generation.
      adopt_session(replacement)
      redirect_to return_to_url || settings_password_path, notice: t("settings.passwords.update.updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

    def set_identity
      @identity = Current.account.identities.find(Current.identity.id)
    end
end
