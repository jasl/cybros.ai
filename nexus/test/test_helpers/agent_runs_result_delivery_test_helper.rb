module AgentRunsResultDeliveryTestHelper
  extend ActiveSupport::Concern
  include InvocationHarness
  include RunLaneTestHelper

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @agent = users(:agent)
      @workspace = workspaces(:shared)
      DevModelLane.ensure_enabled!(@account)
      # Answered by the agent: the engine of every reply head here is the agent's.
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      declare_tools!(@agent, tools: [Nexus::Tools::DELEGATE_TASK, Nexus::Tools::ASK, READ_TOOL])
    end
  end

  def say!(text) = post_input!(@conversation, acting_user: @human, text: text)

  # The person speaks, the agent's reply materializes as a loop-backed turn
  # whose round one is running.
  def open_turn!(text)
    say!(text)
    turn, agent_run = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(agent_run)
    [turn, agent_run]
  end

  # Admission admits everything queued at once, so a round is found through
  # its own invocation, never by luck.
  def attempt_for(agent_run, key)
    invocation_id = loop_node(agent_run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # The running round answers with flat-tool calls; the kernel's jobs run.
  def call_round!(agent_run, key, name, *arguments)
    tool_calls = arguments.each_with_index.map do |fields, index|
      { id: "call_#{name}_#{index}", name: name, arguments: fields.to_json }
    end
    apply_via(attempt_for(agent_run, key), sse_success("delegating", tool_calls: tool_calls))
    AgentRuns::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [AgentRuns::DelegateTaskToolJob, AgentRuns::AskJob, AgentRuns::ScheduleJob]) do
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    end
    agent_run.reload
  end

  # The step converger is where a settled branch reaches quiescence, so a
  # job it enqueues survives this — assert around it.
  def run_round!(agent_run, key, text)
    apply_via(attempt_for(agent_run, key), sse_success(text))
    AgentRuns::ConvergeTerminalSteps.call
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run.reload
  end

  def converge! = Conversations::Turns::Converge.call

  def deliver_result_now!(agent_run) = AgentRuns::ResultDeliveryJob.perform_now(agent_run.id)

  def request_texts(node)
    round_request_entries(node).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  # A person's own `direct_reply` on the conversation the agent answers is a loop-backed turn too:
  # the latest turn's round one carries the history the person's reply read.
  def reply_texts
    persons_loop = @conversation.conversation_turns.order(:position).last.active_variant.agent_run
    schedule_loop!(persons_loop)
    request_texts(loop_node(persons_loop, "r1"))
  end

  def envelope(task, status, prompt, text)
    "<task_result task=\"#{task}\" status=\"#{status}\">\n<prompt>#{prompt}</prompt>\n#{text}\n</task_result>"
  end

  # A turn whose reply is final while its background task still runs.
  def delivered_turn!
    turn, agent_run = open_turn!("run the suite while I keep working")
    call_round!(agent_run, "r1", "delegate_task", { prompt: "long test run" })
    run_round!(agent_run, "r2", "meanwhile, here is what I know")
    [turn, agent_run.reload]
  end
end
