module RunsResultDeliveryTestHelper
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
    turn, run = materialize_loop_reply!(@conversation, agent: @agent, text: nil)
    schedule_loop!(run)
    [turn, run]
  end

  # Admission admits everything queued at once, so a round is found through
  # its own invocation, never by luck.
  def attempt_for(run, key)
    invocation_id = loop_node(run, key).selected_model_invocation_id
    ModelInvocations::AdmitQueuedWork.call
    clear_enqueued_jobs
    ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
  end

  # The running round answers with flat-tool calls; the kernel's jobs run.
  def call_round!(run, key, name, *arguments)
    tool_calls = arguments.each_with_index.map do |fields, index|
      { id: "call_#{name}_#{index}", name: name, arguments: fields.to_json }
    end
    apply_via(attempt_for(run, key), sse_success("delegating", tool_calls: tool_calls))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::DelegateTaskToolJob, Runs::AskJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: run.id)
    end
    run.reload
  end

  # The step converger is where a settled branch reaches quiescence, so a
  # job it enqueues survives this — assert around it.
  def run_round!(run, key, text)
    apply_via(attempt_for(run, key), sse_success(text))
    Runs::ConvergeTerminalSteps.call
    Runs::ScheduleReady.call(run_id: run.id)
    run.reload
  end

  def converge! = Conversations::Turns::Converge.call

  def deliver_result_now!(run) = Runs::ResultDeliveryJob.perform_now(run.id)

  def request_texts(node)
    round_request_entries(node).filter_map { |payload| payload.dig("parts", 0, "text") }
  end

  # A person's own `direct_reply` on the conversation the agent answers is a loop-backed turn too:
  # the latest turn's round one carries the history the person's reply read.
  def reply_texts
    persons_loop = @conversation.turns.order(:position).last.active_variant.run
    schedule_loop!(persons_loop)
    request_texts(loop_node(persons_loop, "r1"))
  end

  def envelope(task, status, prompt, text)
    "<task_result task=\"#{task}\" status=\"#{status}\">\n<prompt>#{prompt}</prompt>\n#{text}\n</task_result>"
  end

  # A turn whose reply is final while its background task still runs.
  def delivered_turn!
    turn, run = open_turn!("run the suite while I keep working")
    call_round!(run, "r1", "delegate_task", { prompt: "long test run" })
    run_round!(run, "r2", "meanwhile, here is what I know")
    [turn, run.reload]
  end
end
