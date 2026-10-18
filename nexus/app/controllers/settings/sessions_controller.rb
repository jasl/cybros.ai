class Settings::SessionsController < Settings::BaseController
  PAGE_SIZE = 10

  def index
    @sessions_pagy, @sessions = pagy(
      :offset,
      Session.listable_for(Current.identity),
      limit: PAGE_SIZE
    )
  end

  # The current Session is deliberately excluded from collection revocation.
  # Ordinary logout ends it directly; password change consumes and replaces it.
  def destroy
    session_record = Current.identity.sessions.where.not(id: Current.session.id).find_by!(public_id: params[:id])
    session_record.destroy
    redirect_to settings_sessions_path, notice: t("settings.sessions.destroy.revoked")
  end
end
