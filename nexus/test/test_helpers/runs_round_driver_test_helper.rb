module RunsRoundDriverTestHelper
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

  def start!(run)
    Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: @human
    ))
    clear_enqueued_jobs
    schedule!(run)
  end

  def schedule!(run)
    Runs::ScheduleReady.call(run_id: run.id)
    clear_enqueued_jobs
  end

  def node(run, key) = run.tasks.find_by!(node_key: key)

  def step_attempt(run, key)
    @admitted ||= {}
    ModelInvocations::AdmitQueuedWork.call.admitted.each do |candidate|
      @admitted[candidate.attempt.model_invocation_id] = candidate.attempt
    end
    clear_enqueued_jobs
    @admitted.fetch(node(run, key).selected_model_invocation_id)
  end

  def run_step!(run, behaviour, key:)
    apply_via(step_attempt(run, key), behaviour)
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    schedule!(run)
  end

  # Every call names the one declared tool; the PATH is what varies.
  # What an external runner does: fetch the parked task, run it, submit.
  def submit!(run, key, content:, is_error: false, outcome: "completed")
    Runs::Parks::Settle.call(
      node: node(run, key), trusted: true,
      content: content, is_error: is_error, outcome: outcome
    )
  end

  def calls(*paths)
    paths.each_with_index.map do |path, index|
      { id: "call_#{index}", name: "read_file", arguments: "{\"path\":\"#{path}\"}" }
    end
  end
end
