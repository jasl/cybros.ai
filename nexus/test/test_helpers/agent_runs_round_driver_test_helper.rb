module AgentRunsRoundDriverTestHelper
  extend ActiveSupport::Concern
  include InvocationHarness

  READ_TOOL = {
    "type" => "function",
    "function" => { "name" => "read_file", "parameters" => { "type" => "object" } },
  }.freeze

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @workspace = workspaces(:shared)
      DevModelLane.ensure_enabled!(@account)
    end
  end

  def model(key, **over) = super(key, "tools" => [READ_TOOL], **over)

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(
      agent_run: agent_run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  def schedule!(agent_run)
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    clear_enqueued_jobs
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def step_attempt(agent_run, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(node(agent_run, key).selected_model_invocation_id)
  end

  def run_step!(agent_run, behaviour, key:)
    apply_via(step_attempt(agent_run, key), behaviour)
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(agent_run)
  end

  # Every call names the one declared tool; the PATH is what varies.
  # What an external runner does: fetch the parked task, run it, submit.
  def submit!(agent_run, key, content:, is_error: false, outcome: "completed")
    AgentRuns::Parks::Settle.call(
      node: node(agent_run, key), trusted: true,
      content: content, is_error: is_error, outcome: outcome
    )
  end

  def calls(*paths)
    paths.each_with_index.map do |path, index|
      { id: "call_#{index}", name: "read_file", arguments: "{\"path\":\"#{path}\"}" }
    end
  end
end
