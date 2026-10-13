class Settings::Tokens::RevocationsController < Settings::BaseController
  def create
    token = Current.user.access_tokens.find_by!(public_id: params[:token_id])
    AccessTokens::Revoke.call(token)
    redirect_to settings_tokens_path, notice: t(".revoked")
  end
end
