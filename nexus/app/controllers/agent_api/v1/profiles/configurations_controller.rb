# PUT /agent_api/v1/profile/configuration — the one writer of the Agent
# Profile's standing declaration: a whole replacement the profile itself
# makes, answered with the profile it now reads back as.
class AgentAPI::V1::Profiles::ConfigurationsController < AgentAPI::V1::BaseController
  serves_plane :member

  def update
    credential = current_credential
    outcome = Users::DeclareProfile.call(user: credential.user, configuration: declaration, **prompt_documents)

    if outcome.accepted?
      render json: AgentAPI::ProfilePresenter.full(
        member: outcome.user, credential: credential, measured_at: Time.current
      )
    elsif outcome.outcome == :invalid
      render_error(:validation_failed, outcome.user.errors.full_messages.to_sentence,
        status: :unprocessable_content)
    else
      render_refusal(outcome.outcome, detail: outcome.detail)
    end
  end

  private

    # This is a whole declaration: omission clears the prior field. JSON
    # values keep their shape until the owning model validates them.
    def declaration
      typed = params.permit(configuration: {}).fetch(:configuration)
        .permit(:approval_mode, :prompt_mechanism, :default_model, :fallback_model)
      {
        tool_definitions: request.request_parameters.dig("configuration", "tool_definitions"),
        kernel_tools: request.request_parameters.dig("configuration", "kernel_tools"),
        runner_executor_public_ids: request.request_parameters.dig("configuration", "runner_executor_public_ids"),
        runner_tool_names: request.request_parameters.dig("configuration", "runner_tool_names"),
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

    # Missing/null clears a slot, but a non-object must not become a deletion.
    # Object envelopes retain empty objects for the prompt writer's normal refusal.
    def prompt_documents
      fields = if params[:prompt_documents].nil?
        ActionController::Parameters.new
      else
        params.permit(prompt_documents: {}).fetch(:prompt_documents)
      end
      {
        system_prompt: prompt_document(fields, :system_prompt),
        summarizer: prompt_document(fields, :summarizer),
      }
    end

    def prompt_document(fields, slot)
      unless fields[slot].nil?
        document = fields.permit(slot => {}).fetch(slot)
        { content: document[:content], role: document[:role]&.to_s }
      end
    end
end
