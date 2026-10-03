# PUT /agent_api/v1/profile/configuration — the one writer of the Agent
# Profile's standing declaration: a whole replacement the profile itself
# makes, answered with the profile it now reads back as.
class AgentAPI::V1::Profiles::ConfigurationsController < AgentAPI::V1::BaseController
  serves_plane :member

  def update
    credential = current_credential
    outcome = Users::DeclareConfiguration.call(user: credential.user, **declaration)

    if outcome.accepted?
      render json: AgentAPI::ProfilePresenter.full(
        member: outcome.user, credential: credential, measured_at: Time.current
      )
    elsif outcome.outcome == :invalid
      render_error(:validation_failed, outcome.user.errors.full_messages.to_sentence,
        status: :unprocessable_content)
    else
      render_refusal(outcome.outcome)
    end
  end

  private

    # This is a whole declaration: omission clears the prior field. JSON
    # values keep their shape until the owning model validates them.
    def declaration
      typed = params.permit(configuration: [:approval_mode, :prompt_mechanism, :default_model, :fallback_model])
        .fetch(:configuration)
      {
        tool_definitions: request.request_parameters.dig("configuration", "tool_definitions"),
        approval_mode: typed[:approval_mode]&.to_s,
        approval_rules: request.request_parameters.dig("configuration", "approval_rules"),
        prompt_mechanism: typed[:prompt_mechanism]&.to_s,
        prompt_template: request.request_parameters.dig("configuration", "prompt_template"),
        compaction_policy: request.request_parameters.dig("configuration", "compaction_policy"),
        lifecycle_hooks: request.request_parameters.dig("configuration", "lifecycle_hooks"),
        default_model: typed[:default_model]&.to_s,
        fallback_model: typed[:fallback_model]&.to_s,
      }
    end
end
