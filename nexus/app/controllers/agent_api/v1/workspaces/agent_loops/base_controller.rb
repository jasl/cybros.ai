# The loop resources' plumbing: the lifecycle verbs' one shape — authorize,
# run, answer with the loop's fresh state; a wrong-state verb is a CONFLICT,
# the loop exists and its state just is not the one the verb needs — and the
# task adjudication verbs' one shape, answering the task's fresh projection.
class AgentAPI::V1::Workspaces::AgentLoops::BaseController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped

  before_action :require_execution_details

  private

    def require_execution_details
      agent_loop = find_listable_loop(@workspace)
      return unless agent_loop.details_pruned_at

      render_error(:execution_details_pruned,
        "Execution details have expired; the conversation text is retained", status: :gone)
    end

    def lifecycle(service, **command)
      agent_loop = find_listable_loop(@workspace)
      result = service.call(service::Command.new(
        agent_loop: agent_loop, acting_user: acting_user, **command
      ))
      render_lifecycle(result, agent_loop)
    end

    # A malformed force is refused (parameter_invalid), never coerced: stop's default
    # is the destructive arm, so "force": "false" falling through would escalate the stated intent.
    def force_param(default: false)
      value = params.fetch(:force, default)
      raise APIErrors::ParameterInvalid, :force unless [true, false].include?(value)

      value
    end

    def render_lifecycle(result, agent_loop)
      case result.outcome
      when :accepted
        render json: { agent_loop: AgentAPI::AgentLoopPresenter.full(agent_loop.reload) }
      when :not_authorized
        render_error(:not_authorized,
          "This workspace is not writable by the caller", status: :forbidden)
      when :not_found
        render_error(:not_found, "Agent loop not found", status: :not_found)
      else
        render_error(result.outcome.to_s, "Refused: #{result.outcome}",
          status: :conflict)
      end
    end

    # The adjudication verbs share one shape: authorize, run, answer with
    # the task's fresh projection. Wrong-state refusals are CONFLICTS.
    def adjudicate(service, **command)
      agent_loop = find_listable_loop(@workspace)
      result = service.call(service::Command.new(
        agent_loop: agent_loop, task_key: params.fetch(:task_key), acting_user: acting_user, **command
      ))

      return render_adjudication_refusal(result.outcome) unless result.outcome == :accepted

      render json: { task: AgentAPI::AgentLoopPresenter.task(result.node.reload) }
    end

    def render_adjudication_refusal(outcome)
      case outcome
      when :not_authorized
        render_error(:not_authorized,
          "This workspace is not writable by the caller", status: :forbidden)
      when :not_found, :task_not_found
        # One code for one miss: GET on the same missing key answers
        # `not_found` through the find_by! rescue, so the verbs do too.
        render_error(:not_found, "Not found", status: :not_found)
      else
        render_error(outcome.to_s, "Refused: #{outcome}", status: :conflict)
      end
    end
end
