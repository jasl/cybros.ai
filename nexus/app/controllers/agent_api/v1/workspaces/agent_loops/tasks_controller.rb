# The append door over HTTP: the envelope carries steps in written order
# plus the concurrency fences — `expected_revision` CAS and the
# Idempotency-Key whose receipt replays under the loop lock.
class AgentAPI::V1::Workspaces::AgentLoops::TasksController <
      AgentAPI::V1::Workspaces::AgentLoops::BaseController
  include AgentAPI::V1::WorkspaceScoped

  CONFLICTS = %i[
    stale_revision agent_loop_not_appendable idempotency_envelope_mismatch
    duplicate_task_key await_not_resolvable tip_live tip_unresolved turn_already_delivered
  ].freeze
  # The old grammar's envelope words, refused by name at the top of the tree.
  REFUSED_ENVELOPE_WORDS = %w[tasks deliverable].freeze

  def create
    # Growth is a WRITE: the same gate every write door in this family
    # holds (live workspace + access + the dedication fence + the hosting
    # conversation's level), AFTER the funnel so a concealed loop is absence.
    agent_loop = find_listable_loop(@workspace)
    return unless authorize_writable(agent_loop)

    # The append grammar: `steps` is the authored tree, read from the
    # parsed body verbatim.
    envelope = request.request_parameters
    refused = (envelope.keys & REFUSED_ENVELOPE_WORDS).first
    if refused
      return render_extended_error(:edge_authoring_refused,
        "#{refused} is not an append field: write steps in order, the kernel places the edges",
        status: :unprocessable_entity, path: refused)
    end
    key = optional_idempotency_key(
        max_bytes: AgentLoopAppendReceipt::IDEMPOTENCY_KEY_MAX_BYTES
      )

    result = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.authored(
      agent_loop: agent_loop,
      steps: envelope["steps"],
      resolves: envelope["resolve"],
      expected_revision: expected_revision(envelope),
      idempotency_key: key,
      creator: acting_user
    ))

    case result.outcome
    when :applied
      # A running loop learns of its new work now; every other state
      # schedules on its own exit (start/resume/adjudication). The kick is
      # level-triggered and deferred to commit — a no-op when not running.
      AgentLoops::ScheduleJob.perform_later(agent_loop.id)
      render json: { receipt: result.receipt }, status: :created
    when :replayed
      # The replay answers the ORIGINAL response, status included.
      render json: { receipt: result.receipt.merge("replayed" => true) },
        status: result.response_status
    when :invalid_steps
      render_extended_error(:invalid_steps, "Step payload failed to compile",
        status: :unprocessable_entity, steps: result.errors)
    when :stale_revision
      render_extended_error(:stale_revision, "The loop changed since it was read",
        status: :conflict, current_revision: agent_loop.reload.revision)
    when *CONFLICTS
      render_error(result.outcome.to_s, "Refused: #{result.outcome}", status: :conflict)
    else
      render_error(result.outcome.to_s, "Refused: #{result.outcome}",
        status: :unprocessable_entity)
    end
  end

  def show
    agent_loop = find_listable_loop(@workspace)
    node = agent_loop.agent_loop_nodes.find_by!(node_key: params.fetch(:key))
    render json: { task: AgentAPI::AgentLoopPresenter.task_detail(node) }
  end

  private

    def expected_revision(envelope)
      value = envelope["expected_revision"]
      return nil if value.nil?

      bounded_integer(value, :expected_revision, range: 0..(2**62))
    end
end
