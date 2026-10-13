# A read-only projection of the tool sources a new execution would assemble.
# The same assembler owns execution snapshots; this door creates no work.
class AgentAPI::V1::Tools::AssembliesController < AgentAPI::V1::Tools::BaseController
  def create
    conversation = assembly_conversation
    principal = conversation&.answering_user || current_credential.user
    runner = ::Executors::InitialRunner.for(requested: selected_runner_id, principal: principal)
    if runner.refused?
      render_refusal(runner.error_key.to_sym, runner.detail)
      return
    end

    configuration = assembly_configuration
    if configuration && !configuration.valid?
      render_error(:validation_failed,
        configuration.errors.map { |error| "#{error.attribute}: #{error.type}" }.join(", "),
        status: :unprocessable_content)
      return
    end

    result = if conversation
      ::Tools::Assemble.for_profile(profile: conversation.declaring_profile,
        declaration: conversation.execution_declaration, runner: runner.executor)
    elsif configuration
      ::Tools::Assemble.call(principal: principal, runner: runner.executor, **configuration.to_h)
    else
      ::Tools::Assemble.for_profile(profile: principal, runner: runner.executor)
    end
    if result.accepted?
      render json: { tool_definitions: result.definitions, environment: result.environment }
    else
      render_refusal(result.refusal)
    end
  end

  private

    def assembly_conversation
      public_id = params.permit(:conversation_public_id)[:conversation_public_id]
      return if public_id.nil?

      raise APIErrors::ParameterInvalid, :configuration if params.key?(:configuration)

      user = current_credential.user
      workspaces = Workspace.data_accessible_to(user).browsable
      Conversation.where(workspace_id: workspaces.select(:id)).listable.readable_by(user)
        .find_by!(public_id: public_id.to_s)
    end

    # Null deliberately selects no Runner; omission must not silently use a
    # default the caller did not name.
    def selected_runner_id
      fields = params.permit(:default_runner_executor_public_id)
      unless fields.key?(:default_runner_executor_public_id)
        raise ActionController::ParameterMissing, :default_runner_executor_public_id
      end

      fields[:default_runner_executor_public_id]&.to_s
    end

    # The four JSON fields retain their shape through the object envelope;
    # the shared declaration/import validators own their semantic grammar.
    def assembly_configuration
      return unless params.key?(:configuration)

      fields = params.permit(configuration: {}).fetch(:configuration).to_h
      ::Tools::AssemblyConfiguration.new(
        tool_definitions: fields["tool_definitions"], kernel_tools: fields["kernel_tools"],
        runner_executor_public_ids: fields["runner_executor_public_ids"], runner_tool_names: fields["runner_tool_names"]
      )
    end
end
