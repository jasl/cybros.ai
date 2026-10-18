class Conversations::Schedules::BaseController < Conversations::BaseController
  before_action :set_schedule

  private

    def set_schedule
      @job = @conversation.schedules.including_context.find_by!(public_id: params.fetch(:schedule_id))
    end

    def transition(command)
      render_schedule_result(::Schedules::Manage.transition(@job, command, by: acting_user))
    end

    def render_schedule_result(result)
      if result.accepted?
        redirect_to conversation_schedule_path(@conversation, @job,
          return_to: work_return_path(conversation_schedules_path(@conversation))), status: :see_other,
          notice: t("schedules_console.command_accepted")
      else
        @command_error = result.invalid? ? result.errors.full_messages.to_sentence :
          helpers.schedule_refusal(result.outcome)
        @projection = ::Schedules::Projection.full(@job, by: acting_user)
        @read_at = Time.current
        status = Nexus::FamilyErrors.status_for(result.outcome) ||
          AgentAPI::V1::BaseController::REFUSAL_STATUSES.fetch(result.outcome, :unprocessable_content)
        render "conversations/schedules/show", status: status
      end
    end
end
