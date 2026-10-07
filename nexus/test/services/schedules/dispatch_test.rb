require "test_helper"
require_relative "../../test_helpers/inputs_apply_next_test_helper"

class Schedules::DispatchTest < ActiveSupport::TestCase
  include InputsApplyNextTestHelper
  include AgentMembershipTestHelper

  NOW = Time.utc(2026, 10, 2)

  setup { answered_by!(@agent) }

  test "a due occurrence creates one child and input even when its wake is repeated" do
    job = create_job!

    assert_equal :not_due, dispatch(job, at: NOW + 59)
    assert_difference -> { Conversation.count }, 1 do
      assert_difference -> { ConversationInput.count }, 1 do
        assert_equal :dispatched, dispatch(job, at: NOW + 60)
        assert_equal :not_due, dispatch(job, at: NOW + 60)
      end
    end

    child = job.reload.execution_conversations.sole
    input = child.conversation_inputs.sole
    assert_equal @conversation, child.parent_conversation
    assert_equal job.public_id, child.schedule_public_id
    assert_equal NOW + 60, child.scheduled_for
    assert_equal input.public_id, child.scheduled_input_public_id
    assert_equal input.public_id, job.last_input_public_id
    assert_equal child, job.last_execution_conversation
    assert_equal NOW + 120, job.next_run_at
    assert_equal "Check the latest status.", input.text
    assert_empty @conversation.conversation_inputs
  end

  test "a busy main conversation does not prevent the child from starting its own turn" do
    main = create_run_backed_turn(conversation: @conversation, acting_user: @user)
    job = create_job!

    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    child = job.reload.last_execution_conversation
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)

    assert_equal main.turn, @conversation.reload.active_turn
    assert_equal "running", main.turn.reload.status
    assert_equal "running", main.agent_run.reload.status
    assert_equal "running", child.reload.active_turn.status
    assert_equal child.active_turn.public_id, child.scheduled_turn_public_id
    assert_empty @conversation.conversation_inputs
  end

  test "long downtime coalesces missed occurrences and keeps the interval anchor" do
    job = create_job!
    late = NOW + 3607

    assert_equal :dispatched, dispatch(job, at: late)
    assert_equal :not_due, dispatch(job, at: late)

    assert_equal 1, job.execution_conversations.count
    assert_equal NOW + 60, job.execution_conversations.sole.scheduled_for
    assert_equal NOW + 3660, job.reload.next_run_at
    assert_equal late, job.last_enqueued_at
  end

  test "birth reads the current parent memory and access carrier and copies its billing and eligible runner" do
    subject = BillingSubject.create!(account: @account, owning_user: @user, key: "scheduled-work")
    runner = connect_runner(manager: users(:owner), registration_identifier: "scheduled-runner",
      assignment_scope: :account_wide).executor_access_token.task_executor
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: @agent,
      billing_subject_key: subject.key, billing_subject_public_id: subject.public_id, default_runner_executor: runner)
    job = create_job!
    @conversation.update!(memory_context: { "bindings" => [] }, access_default: "read")

    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    child = job.reload.last_execution_conversation
    assert_equal({ "bindings" => [] }, child.memory_context)
    assert_equal "read", child.access_default
    assert_equal [subject.key, subject.public_id], [child.billing_subject_key, child.billing_subject_public_id]
    assert_equal runner, child.default_runner_executor
    assert child.writable_by?(@user)
    assert child.writable_by?(@agent)
    assert_equal @agent, child.memory_principal(@user)
  end

  test "a queued execution skips the next occurrence and later dispatch resumes after it leaves" do
    job = create_job!
    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    child = job.reload.last_execution_conversation
    input = child.conversation_inputs.sole

    assert_equal :execution_in_progress, dispatch(job, at: NOW + 120)
    assert_equal 1, job.execution_conversations.count
    assert_equal NOW + 180, job.reload.next_run_at
    assert_equal "execution_in_progress", job.last_error_code

    removed = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: child, input_public_id: input.public_id, acting_user: @user
    ))
    assert_predicate removed, :accepted?
    assert_equal :dispatched, dispatch(job, at: NOW + 180)
    assert_equal 2, job.execution_conversations.count
    assert_equal NOW + 180, job.reload.last_execution_conversation.scheduled_for
    assert_nil job.last_error_code
  end

  test "a materialized running execution prevents another child after the input is consumed" do
    job = create_job!
    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    child = job.reload.last_execution_conversation
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    assert_empty child.conversation_inputs
    assert_equal "running", child.reload.active_turn.status

    assert_equal :execution_in_progress, dispatch(job, at: NOW + 120)
    assert_equal 1, job.execution_conversations.count
    assert_equal NOW + 180, job.reload.next_run_at
  end

  test "losing the creator's parent access blocks dispatch without advancing its clock" do
    job = create_job!(creating_user: users(:curator))
    @conversation.update!(access_default: "none")

    assert_equal :not_authorized, dispatch(job, at: NOW + 60)
    assert_empty job.execution_conversations
    assert_equal "not_authorized", job.reload.last_error_code
    assert_equal NOW + 60, job.next_run_at

    @conversation.update!(access_default: "full")
    assert_equal :dispatched, dispatch(job, at: NOW + 65)
    assert_equal 1, job.execution_conversations.count
    assert_nil job.reload.last_error_code
  end

  test "an archived parent blocks dispatch until it is restored" do
    job = create_job!
    assert_predicate Conversations::Archive.call(conversation: @conversation), :accepted?

    assert_equal :conversation_archived, dispatch(job, at: NOW + 60)
    assert_empty job.execution_conversations
    assert_equal NOW + 60, job.reload.next_run_at
    assert_equal "conversation_archived", job.last_error_code

    assert_predicate Conversations::Unarchive.call(conversation: @conversation), :accepted?
    assert_equal :dispatched, dispatch(job, at: NOW + 65)
  end

  test "an answerer removed after creation cannot start scheduled work" do
    job = create_job!
    assert_equal :removed, @agent.remove

    assert_equal :answerer_not_eligible, dispatch(job, at: NOW + 60)
    assert_empty job.execution_conversations
    assert_equal "answerer_not_eligible", job.reload.last_error_code
  end

  test "dispatch preserves the creator's ingress speaker and the input's narrowed policy" do
    declare!(@agent, tools: [READ_TOOL, WRITE_TOOL])
    speaker = Speaker.register_ingress(user: @agent, channel_key: "chat", external_id: "scheduled-speaker",
      display_name: "Scheduled speaker")
    assert_predicate speaker, :persisted?
    job = create_job!(creating_user: @agent, speaker_public_id: speaker.public_id,
      tool_names: ["read_file"], approval_mode: "ask", configuration: { "max_output_tokens" => 64 })

    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    child = job.reload.last_execution_conversation
    input = child.conversation_inputs.sole
    assert_equal @agent, input.authoring_user
    assert_equal @agent, input.answering_user
    assert_equal speaker, input.speaker
    assert_equal ["read_file"], input.tool_names
    assert_equal "ask", input.approval_mode
    assert_equal({ "max_output_tokens" => 64 }, input.request_options)

    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    loop = child.reload.active_turn.active_variant.agent_run
    assert_equal "ask", loop.approval_mode
    assert_equal [READ_TOOL], loop.agent_run_tasks.sole.tool_definitions
    assert_equal [READ_TOOL, WRITE_TOOL], @agent.reload.tool_definitions
  end

  test "an old creating loop is provenance and stopping it does not cancel the schedule" do
    source = create_run_backed_turn(conversation: @conversation, acting_user: @user).agent_run
    task = runner_tool_row(source, "schedule", claimed: false, role: nil)
    job = create_job!(source_run_public_id: source.public_id, source_task_key: task.node_key)
    stopped = AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: source, acting_user: @user))
    assert_predicate stopped, :accepted?
    assert_predicate source.reload, :stopped?

    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    assert_predicate job.reload, :active?
    input = job.last_execution_conversation.conversation_inputs.sole
    assert_nil input.sender_run_public_id
    assert_nil input.sender_task_key
    assert_equal source.public_id, job.source_run_public_id
  end

  test "a one-time schedule completes after its sole child is accepted" do
    job = create_job!(rule: { "kind" => "once", "run_at" => (NOW + 60).iso8601 })

    assert_equal :dispatched, dispatch(job, at: NOW + 60)
    assert_predicate job.reload, :completed?
    assert_nil job.next_run_at
    assert_equal :not_due, dispatch(job, at: NOW + 3600)
    assert_equal 1, job.execution_conversations.count
  end

  private

    def create_job!(creating_user: @user, **attributes)
      result = DatabaseClock.stub(:now, NOW) do
        Schedules::Create.call(conversation: @conversation, creating_user: creating_user, attributes: {
          name: "Status check", prompt: "Check the latest status.", provider_id: "dev", model_ref: "mock-text",
          rule: { "kind" => "interval", "every_seconds" => 60, "starts_at" => (NOW + 60).iso8601 },
        }.merge(attributes))
      end
      assert_predicate result, :accepted?, result.outcome.to_s
      result.value
    end

    def dispatch(job, at:) = Schedules::Dispatch.call(id: job.id, cutoff: at)
end
