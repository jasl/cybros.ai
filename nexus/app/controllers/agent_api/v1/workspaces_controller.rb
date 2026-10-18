# The Workspace collection on the member plane: keyset-listed,
# browsable-scoped reads, receipt-idempotent creation, and owner-only
# optimistic management.
class AgentAPI::V1::WorkspacesController < AgentAPI::V1::Workspaces::BaseController
  def index
    scope = state_scope(Workspace.data_accessible_to(acting_user))
    scope = dedication_scope(scope)
    page = keyset_page(scope, columns: { public_id: :uuid })

    render json: {
      workspaces: page.records.map { |workspace| AgentAPI::WorkspacePresenter.basic(workspace) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    workspace = find_browsable_workspace

    render json: { workspace: AgentAPI::WorkspacePresenter.full(workspace) }
  end

  def create
    key = required_idempotency_key
    return if performed?
    return unless reject_explicit_nulls(:workspace, %i[name access_mode metadata])
    # The public Workspace contract makes present metadata object-only.
    return unless reject_non_object_metadata(:workspace)

    envelope = create_envelope
    outcome = WorkspaceCommandReceipt::Idempotent.call(
      account: current_account,
      acting_user: acting_user,
      operation: :workspace_create,
      idempotency_key: key,
      request_digest: WorkspaceCommandReceipt.digest_for(operation: :workspace_create, envelope: envelope),
    ) do
      result = ::Workspaces::Create.call(
        creator: acting_user,
        name: envelope["name"],
        access_mode: envelope["access_mode"],
        metadata: envelope["metadata"],
      )
      if result.outcome == :created
        WorkspaceCommandReceipt::Idempotent::Success.new(
          status: 201,
          body: { workspace: AgentAPI::WorkspacePresenter.full(result.workspace) },
          workspace: result.workspace,
        )
      else
        result
      end
    end

    render_idempotent_outcome(outcome) do |receipt|
      # Replay renders the stored response only through the caller's current
      # scope: access loss or a tombstone conceals it like absence.
      Workspace.data_accessible_to(acting_user).browsable.find_by(id: receipt.workspace_id)
    end
  end

  def update
    workspace = find_browsable_workspace
    return unless reject_explicit_nulls(:workspace, %i[metadata])
    # The public Workspace contract makes present metadata object-only.
    return unless reject_non_object_metadata(:workspace)

    fields = params.expect(workspace: [:name, { metadata: {} }, :lock_version])
    lock_version = lock_version_from(fields)
    changes = {}
    changes[:name] = fields[:name] if fields.key?(:name)
    changes[:metadata] = fields[:metadata].to_h if fields.key?(:metadata)
    if changes.empty?
      return render_error(:validation_failed, "Provide name or metadata to update", status: :unprocessable_entity)
    end

    result = ::Workspaces::Update.call(
      workspace: workspace, by: acting_user, lock_version: lock_version, **changes
    )
    render_workspace_result(result)
  end

  def destroy
    workspace = find_browsable_workspace
    lock_version = bounded_integer(params[:lock_version], :lock_version, range: LOCK_VERSION_RANGE)

    result = ::Workspaces::Delete.call(workspace: workspace, by: acting_user, lock_version: lock_version)
    render_workspace_result(result)
    complete_transition_after(result)
  end

  private

    def state_scope(scope)
      case params[:state]
      when nil
        scope.live
      when "archived"
        scope.where(state: %w[archiving archived])
      else
        raise APIErrors::ParameterInvalid, :state
      end
    end

    def dedication_scope(scope)
      case params[:dedicated_to_current_agent]
      when nil, "false"
        if acting_user.agent_member?
          scope.where(agent_identifier: nil)
        else
          scope
        end
      when "true"
        if acting_user.agent_member?
          scope.where(agent_identifier: acting_user.agent_identifier)
        else
          scope.none
        end
      else
        raise APIErrors::ParameterInvalid, :dedicated_to_current_agent
      end
    end

    # The accepted request envelope is principal-specific: Humans may choose
    # access mode, while Agent creation is always private and server-dedicated
    # from the authenticated Profile. Unknown fields are ignored.
    def create_envelope
      fields = if acting_user.human?
        params.expect(workspace: [:name, :access_mode, { metadata: {} }])
      else
        params.expect(workspace: [:name, { metadata: {} }])
      end
      fields.to_h.tap do |envelope|
        # `expect` requires only the root; an absent (or permit-dropped
        # non-scalar) name is this endpoint's own required-field 400.
        raise ActionController::ParameterMissing.new(:name) unless envelope.key?("name")

        envelope["name"] = envelope["name"].to_s
      end
    end

    def reject_non_object_metadata(root)
      container = params[root]
      case container
      when ActionController::Parameters
        if container.key?(:metadata)
          case container[:metadata]
          when ActionController::Parameters, nil
            true
          else
            render_error(
              :validation_failed, "metadata must be a JSON object", status: :unprocessable_entity
            )
            false
          end
        else
          true
        end
      else
        true
      end
    end
end
