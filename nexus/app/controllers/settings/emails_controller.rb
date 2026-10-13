class Settings::EmailsController < Settings::BaseController
  before_action :set_identity

  rate_limit to: 10, within: 3.minutes,
    by: -> { Current.user.public_id },
    scope: "settings/current-password",
    only: :update,
    with: -> { redirect_to settings_email_path, alert: t("settings.current_password_rate_limited") }

  def show
  end

  def update
    submitted = params.expect(email: [:current_password, :email])
    email = submitted[:email].to_s

    if @identity.change_email(email, current_password: submitted[:current_password].to_s)
      redirect_to settings_email_path, notice: t("settings.emails.update.updated")
    else
      @identity.email = email
      render :show, status: :unprocessable_entity
    end
  end

  private

    def set_identity
      @identity = Current.account.identities.find(Current.identity.id)
    end
end
