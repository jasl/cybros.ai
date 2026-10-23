# The loop surface: create with the seed envelope, read the task-grained trace.
# Steps are placed in written order and no client authors an edge — the old
# grammar's words are refused by name, which keeps the graph sound.
class AgentAPI::V1::Workspaces::RunsController <
      AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::V1::WorkspaceScoped
  include AgentAPI::SpeakerParameters
  include AgentAPI::MemoryContextParameters
  include RunListing

  # `approval_rules` is opaque JSON read from the parsed body, like the
  # steps; the create refuses its grammar by name.
  SHELL_FIELDS = %w[
    steps billing_subject prompt_mechanism approval_mode approval_rules default_runner_executor_public_id speaker_public_id
    model_selection fallback_models memory_context
  ].freeze
  # A client naming an edge, the answer or a step's own surface on the
  # shell is told so by name, never silently ignored.
  REFUSED_SHELL_WORDS = %w[tasks deliverable tools compaction_policy].freeze

  def index
    scope = filtered_runs(Run.visible_to(acting_user, workspace: @workspace))
    page = keyset_page(scope, columns: { public_id: :uuid })
    render json: {
      runs: AgentAPI::RunPresenter.basic_many(page.records),
      pagination: { next_after: page.next_after },
    }
  end

  def show
    run = find_listable_loop(@workspace, param: :public_id)
    render json: { run: AgentAPI::RunPresenter.full(run) }
  end

  def create
    envelope = create_envelope
    return if performed?

    result = Runs::Create.call(Runs::Create::Command.new(
      workspace: @workspace,
      creating_user: acting_user,
      steps: envelope["steps"],
      billing_subject: envelope["billing_subject"],
      prompt_mechanism: envelope["prompt_mechanism"],
      approval_mode: envelope["approval_mode"],
      approval_rules: envelope["approval_rules"],
      default_runner_executor_public_id: envelope["default_runner_executor_public_id"],
      speaker_public_id: envelope["speaker_public_id"],
      model_selection: envelope["model_selection"],
      fallback_models: envelope["fallback_models"],
      memory_context: envelope["memory_context"],
      idempotency_key: optional_idempotency_key(
        max_bytes: RunAppendReceipt::IDEMPOTENCY_KEY_MAX_BYTES
      )
    ))

    case result.outcome
    when :created
      render json: {
        run: AgentAPI::RunPresenter.full(result.run),
        receipt: result.receipt,
      }, status: :created
    when :replayed
      # Recover the loop's address and the seed receipt's answer tokens.
      render json: {
        run: AgentAPI::RunPresenter.full(result.run),
        receipt: result.receipt,
        replayed: true,
      }
    when :invalid_steps
      render_compile_errors(result.errors)
    when :not_authorized
      render_error(:not_authorized,
        "This workspace is not writable by the caller", status: :forbidden)
    else
      render_error(result.outcome.to_s, "Refused: #{result.outcome}",
        status: :unprocessable_entity)
    end
  end

  # Soft delete: the loop leaves every product surface now and its rows are
  # reclaimed after the retention window. A LIVE loop refuses — stopping a
  # run is `stop`'s decision to make, never a side effect of hiding it.
  def destroy
    run = find_listable_loop(@workspace, param: :public_id)
    return unless authorize_writable(run)

    result = Runs::Tombstone.call(run: run)

    case result.outcome
    when :accepted then head :no_content
    when :not_found then render_error(:not_found, "Agent loop not found", status: :not_found)
    else
      render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :conflict)
    end
  end

  private

    def create_envelope
      params.expect(run: {})
      envelope = Hash.try_convert(request.request_parameters["run"]) or
        raise APIErrors::ParameterInvalid, :run
      # The write grammar is steps; raw node/edge vocabulary is refused
      # loudly, never silently ignored (the predecessor's own guard).
      if envelope.key?("nodes") || envelope.key?("edges")
        render_error(:graph_authoring_not_available,
          "Author steps; the graph is read on its own route, never written",
          status: :unprocessable_entity)
        return {}
      end
      refused = (envelope.keys & REFUSED_SHELL_WORDS).first
      if refused
        render_extended_error(:edge_authoring_refused,
          "#{refused} is not a create field: write steps in order, the kernel places the edges",
          status: :unprocessable_entity, path: "run.#{refused}")
        return {}
      end
      envelope.slice(*SHELL_FIELDS).merge(
        "memory_context" => memory_context_parameter(params.fetch(:run)),
        "speaker_public_id" => speaker_public_id_parameter(envelope["speaker_public_id"]))
    end

    def render_compile_errors(errors)
      render_extended_error(:invalid_steps, "Step payload failed to compile",
        status: :unprocessable_entity, steps: errors)
    end
end
