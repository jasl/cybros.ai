class Settings::ProfilesController < Settings::BaseController
  before_action :set_user

  def show
  end

  def update
    # The fields the form sent, and only those: a form without the handle
    # (or the name) leaves it as it stands.
    attributes = params.expect(profile: [:display_name, :handle])
    # Reload before assigning: overlapping renames must reserve and narrate
    # the last committed handle, not the request's earlier row image.
    updated = @user.with_lock { @user.update(attributes) }

    if updated
      redirect_to settings_path, notice: t("settings.profiles.update.updated")
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

    # The form owns its dirty state without mutating the Current record used
    # by the surrounding application shell.
    def set_user
      @user = Current.account.users.find(Current.user.id)
    end
end
