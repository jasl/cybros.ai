class AgentAPI::V1::Workspaces::Conversations::ScheduledJobsController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped

  def index
    conversation = find_listable_conversation(@workspace)
    scope = conversation.scheduled_jobs.includes(:conversation, :creating_user, :answering_user)
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: { scheduled_jobs: AgentAPI::ScheduledJobPresenter.many(page.records, by: acting_user, workspace: @workspace),
      pagination: { next_after: page.next_after } }
  end

  def show
    render json: { scheduled_job: AgentAPI::ScheduledJobPresenter.full(find_job, by: acting_user) }
  end

  def create
    conversation = find_listable_conversation(@workspace)
    key = required_idempotency_key
    return if performed?

    envelope = submitted_fields
    result = ConversationCommandReceipt::Idempotent.call(
      account: current_account, workspace: @workspace, acting_user: acting_user,
      operation: :scheduled_job_create, idempotency_key: key, host: conversation,
      request_digest: ConversationCommandReceipt.digest_for(operation: :scheduled_job_create, envelope: envelope)
    ) do
      attributes = intent_attributes(conversation, envelope)
      next attributes unless attributes.accepted?

      created = ::ScheduledJobs::Create.call(conversation: conversation, creating_user: acting_user,
        attributes: attributes.value)
      next created unless created.accepted?

      ConversationCommandReceipt::Idempotent::Success.new(status: 201,
        body: { scheduled_job: AgentAPI::ScheduledJobPresenter.full(created.value, by: acting_user) }, host: conversation)
    end
    render_idempotent_outcome(result)
  end

  def update
    job = find_job
    fields = submitted_fields
    version = bounded_integer(fields.delete("expected_lock_version"), :expected_lock_version, range: LOCK_VERSION_RANGE)
    attributes = intent_attributes(job.conversation, fields)
    return render_refused(attributes) unless attributes.accepted?

    render_result(::ScheduledJobs::Manage.revise(job, attributes.value, by: acting_user, expected_lock_version: version))
  end

  private

    def find_job
      find_listable_conversation(@workspace).scheduled_jobs.find_by!(public_id: params.fetch(:public_id))
    end

    def render_result(result)
      if result.accepted?
        render json: { scheduled_job: AgentAPI::ScheduledJobPresenter.full(result.value, by: acting_user) }
      else
        render_refused(result)
      end
    end

    def submitted_fields
      fields = params.permit(scheduled_job: [
        :name, :prompt, :approval_mode, :answering_user_public_id, :speaker_actor_public_id,
        :source_agent_loop_public_id, :source_task_key,
        :expected_lock_version, { rule: %i[kind run_at every_seconds starts_at local_time time_zone],
          model: %i[model reasoning_effort], configuration: {}, tool_names: [] },
      ]).fetch(:scheduled_job).to_h
      fields.except!("source_agent_loop_public_id", "source_task_key") unless action_name == "create"
      supplied = params.fetch(:scheduled_job)
      if supplied.key?(:tool_names)
        names = supplied[:tool_names]
        if names
          names = Array.try_convert(names)
          raise APIErrors::ParameterInvalid, :tool_names unless names&.all? { |name| String.try_convert(name) }
        end
        fields["tool_names"] = names
      end
      %w[speaker_actor_public_id source_agent_loop_public_id].each do |field|
        value = fields[field]
        raise APIErrors::ParameterInvalid, field if value && !ConversationInput.uuid_shaped?(value)
      end
      fields
    end

    def intent_attributes(conversation, fields)
      attributes = fields.except("model", "answering_user_public_id", "expected_lock_version")
      if fields.key?("model")
        provider, model, effort = split_model(fields["model"])
        attributes.merge!("provider_id" => provider, "model_ref" => model, "reasoning_effort" => effort)
      end
      if fields.key?("rule")
        attributes["rule"] = ScheduledJob::Rule.parse(fields["rule"]).to_h
      end
      if fields.key?("answering_user_public_id")
        resolved = ::Conversations::TurnPrincipals.resolve(host: conversation, author: acting_user,
          address: fields["answering_user_public_id"])
        return resolved unless resolved.accepted?

        attributes["answering_user"] = resolved.value.answerer
      end
      ::Conversations::Outcome.accepted(attributes)
    end
end
