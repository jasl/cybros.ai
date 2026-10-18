# Human work pages use the browser Session. The domain scopes remain the
# same ones used by member API readers; management roles add no content access.
class Work::BaseController < ApplicationController
  include APIErrors
  include WorkScope
  helper_method :work_return_path

  private

    def acting_user = Current.user
    def current_account = Current.account

    def work_return_path(fallback)
      return_path(params[:return_to]) || fallback
    end

    def find_visible_conversation(param = :id)
      Conversation.visible_to(acting_user).find_by!(public_id: params.fetch(param))
    end

    def find_visible_run(param = :id)
      Run.visible_to(acting_user).find_by!(public_id: params.fetch(param))
    end

    def render_error(code, message, status:)
      message = t("work_console.error.codes.#{code}", default: message)
      render "work/error", locals: { code: code, message: message },
        status: Nexus::FamilyErrors.status_for(code) || status
    end
end
