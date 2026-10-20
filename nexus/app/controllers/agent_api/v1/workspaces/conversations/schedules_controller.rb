class AgentAPI::V1::Workspaces::Conversations::SchedulesController <
      AgentAPI::V1::Workspaces::Conversations::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include ScheduleListing

  def index
    conversation = find_listable_conversation(@workspace)
    scope = filtered_schedules(conversation.schedules).including_context
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: { schedules: ::Schedules::Projection.many(page.records, by: acting_user, workspace: @workspace),
      pagination: { next_after: page.next_after } }
  end

  def show
    render json: { schedule: ::Schedules::Projection.full(find_job, by: acting_user) }
  end

  def create
    conversation = find_listable_conversation(@workspace)
    key = required_idempotency_key
    return if performed?

    envelope = submitted_fields
    result = ConversationCommandReceipt::Idempotent.call(
      account: current_account, workspace: @workspace, acting_user: acting_user,
      operation: :schedule_create, idempotency_key: key, host: conversation,
      request_digest: ConversationCommandReceipt.digest_for(operation: :schedule_create, envelope: envelope)
    ) do
      attributes = intent_attributes(conversation, envelope)
      next attributes unless attributes.accepted?

      created = ::Schedules::Create.call(conversation: conversation, creating_user: acting_user,
        attributes: attributes.value)
      next created unless created.accepted?

      ConversationCommandReceipt::Idempotent::Success.new(status: 201,
        body: { schedule: ::Schedules::Projection.full(created.value, by: acting_user) }, host: conversation)
    end
    render_idempotent_outcome(result)
  end

  def update
    job = find_job
    fields = submitted_fields
    version = bounded_integer(fields.delete("expected_lock_version"), :expected_lock_version, range: LOCK_VERSION_RANGE)
    attributes = intent_attributes(job.conversation, fields, job: job)
    return render_refused(attributes) unless attributes.accepted?

    render_result(::Schedules::Manage.revise(job, attributes.value, by: acting_user, expected_lock_version: version))
  end

  private

    def find_job
      find_listable_conversation(@workspace).schedules.find_by!(public_id: params.fetch(:public_id))
    end

    def render_result(result)
      if result.accepted?
        render json: { schedule: ::Schedules::Projection.full(result.value, by: acting_user) }
      else
        render_refused(result)
      end
    end

    def submitted_fields
      fields = params.permit(schedule: [
        :name, :prompt, :approval_mode, :answering_user_public_id, :speaker_public_id,
        :source_run_public_id, :source_task_key,
        :expected_lock_version, { rule: %i[kind run_at every_seconds starts_at local_time time_zone],
          model: %i[model reasoning_effort reasoning_enabled], model_selection: {}, fallback_models: [],
          configuration: {}, executor_contexts: {}, tool_names: [] },
      ]).fetch(:schedule).to_h
      fields.except!("source_run_public_id", "source_task_key") unless action_name == "create"
      supplied = params.fetch(:schedule)
      if supplied.key?(:executor_contexts) && !fields.key?("executor_contexts")
        raise APIErrors::ParameterInvalid, :executor_contexts
      end
      fields["fallback_models"] = nil if supplied.key?(:fallback_models) && supplied[:fallback_models].nil?
      if supplied.key?(:tool_names)
        names = supplied[:tool_names]
        if names
          names = Array.try_convert(names)
          raise APIErrors::ParameterInvalid, :tool_names unless names&.all? { |name| String.try_convert(name) }
        end
        fields["tool_names"] = names
      end
      %w[speaker_public_id source_run_public_id].each do |field|
        value = fields[field]
        raise APIErrors::ParameterInvalid, field if value && !Input.uuid_shaped?(value)
      end
      fields
    end

    def intent_attributes(conversation, fields, job: nil)
      ::Schedules::Intent.resolve(conversation: conversation, fields: fields, by: acting_user, job: job,
        model_controls: (split_model(fields["model"]) if fields.key?("model")))
    end
end
