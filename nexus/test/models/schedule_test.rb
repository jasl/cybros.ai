require "test_helper"
require_relative "../test_helpers/inputs_apply_next_test_helper"

class ScheduleTest < ActiveSupport::TestCase
  include InputsApplyNextTestHelper

  NOW = Time.utc(2026, 10, 2)

  setup { answered_by!(@agent) }

  test "creation keeps the instruction and future clock without starting an execution" do
    job = create_job!

    assert_equal @account, job.account
    assert_equal @user, job.creating_user
    assert_equal @agent, job.answering_user
    assert_equal NOW + 60, job.next_run_at
    assert_predicate job, :active?
    assert_empty job.execution_conversations
    assert_empty @conversation.conversation_inputs
  end

  test "a side cannot accept a schedule whose execution would be forbidden to spawn" do
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user, answering_user: @agent, side: true)
    assert_no_difference -> { Schedule.count } do
      assert_equal :side_conversation, create_job.outcome
    end
  end

  test "an elapsed once rule and a date beyond the future bound refuse without a row" do
    [NOW, NOW - 60, NOW + Schedule::FUTURE_BOUND + 1].each do |at|
      assert_no_difference -> { Schedule.count } do
        result = create_job(rule: { "kind" => "once", "run_at" => at.iso8601 })
        assert_predicate result, :invalid?, at.iso8601
        assert result.record.errors.of_kind?(:rule, :invalid)
      end
    end
  end

  test "pause blocks future dispatch and resume skips the elapsed occurrences" do
    job = create_job!

    assert_predicate Schedules::Manage.transition(job, :pause, by: @user), :accepted?
    assert_predicate job.reload, :paused?
    assert_nil job.next_run_at
    assert_equal :not_due, Schedules::Dispatch.call(id: job.id, cutoff: NOW + 300)
    assert_empty job.execution_conversations

    resumed = DatabaseClock.stub(:now, NOW + 307) { Schedules::Manage.transition(job, :resume, by: @user) }
    assert_predicate resumed, :accepted?
    assert_predicate job.reload, :active?
    assert_equal NOW + 360, job.next_run_at
  end

  test "pause leaves an accepted child queued while cancel removes that waiting input" do
    job = create_job!
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: NOW + 60)
    child = job.reload.last_execution_conversation
    input = child.conversation_inputs.sole

    assert_predicate Schedules::Manage.transition(job, :pause, by: @user), :accepted?
    assert_equal input.public_id, child.conversation_inputs.sole.public_id

    assert_predicate Schedules::Manage.transition(job, :cancel, by: @user), :accepted?
    assert_predicate job.reload, :canceled?
    assert_nil job.next_run_at
    assert_empty child.conversation_inputs
    assert_equal 1, job.execution_conversations.count
    assert_equal 1, child.conversation_event_items.where(item_type: "input_deleted").count
    assert_predicate Schedules::Manage.transition(job, :cancel, by: @user), :accepted?
    assert_equal 1, child.conversation_event_items.where(item_type: "input_deleted").count
    assert_equal :schedule_finished, Schedules::Manage.transition(job, :resume, by: @user).outcome
  end

  test "cancel after materialization leaves the running child under ordinary execution control" do
    declare!(@agent)
    job = create_job!
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: NOW + 60)
    child = job.reload.last_execution_conversation
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    turn = child.reload.active_turn
    loop = turn.active_variant.agent_run

    assert_predicate Schedules::Manage.transition(job, :cancel, by: @user), :accepted?
    assert_predicate job.reload, :canceled?
    assert_equal "running", turn.reload.status
    assert_equal "running", loop.reload.status
    assert_not loop.stopped?
    assert_equal :not_due, Schedules::Dispatch.call(id: job.id, cutoff: NOW + 120)
  end

  test "an optimistic edit changes the prompt once and a stale edit leaves it intact" do
    job = create_job!
    version = job.lock_version

    result = Schedules::Manage.revise(job, { prompt: "New instruction" }, by: @user, expected_lock_version: version)
    assert_predicate result, :accepted?
    assert_equal "New instruction", job.reload.prompt
    assert_equal NOW + 60, job.next_run_at

    stale = Schedules::Manage.revise(job, { prompt: "Stale instruction" }, by: @user, expected_lock_version: version)
    assert_equal :stale_object, stale.outcome
    assert_equal "New instruction", job.reload.prompt
  end

  test "editing a paused rule does not resume it" do
    job = create_job!
    assert_predicate Schedules::Manage.transition(job, :pause, by: @user), :accepted?
    edited = DatabaseClock.stub(:now, NOW + 30) do
      Schedules::Manage.revise(job, { rule: { "kind" => "interval", "every_seconds" => 120, "starts_at" => NOW.iso8601 } },
        by: @user, expected_lock_version: job.lock_version)
    end

    assert_predicate edited, :accepted?
    assert_predicate job.reload, :paused?
    assert_nil job.next_run_at
    resumed = DatabaseClock.stub(:now, NOW + 307) { Schedules::Manage.transition(job, :resume, by: @user) }
    assert_predicate resumed, :accepted?
    assert_equal NOW + 360, job.reload.next_run_at
  end

  test "the ordinary input validation rejects tools outside the declaration and looser approval" do
    declare!(@agent, approval_mode: "ask")

    tools = create_job(tool_names: ["write_file"])
    assert_predicate tools, :invalid?
    assert tools.record.errors.of_kind?(:tool_names, :not_declared)

    approval = create_job(approval_mode: "bypass")
    assert_predicate approval, :invalid?
    assert approval.record.errors.of_kind?(:approval_mode, :not_tightening)
    assert_empty @conversation.schedules
    assert_empty @conversation.conversation_inputs
  end

  test "an ingress speaker must belong to the creating agent" do
    speaker = Speaker.register_ingress(user: @agent, channel_key: "chat", external_id: "scheduled-speaker",
      display_name: "Scheduled speaker")
    assert_predicate speaker, :persisted?

    refused = create_job(speaker_public_id: speaker.public_id)
    assert_predicate refused, :invalid?
    assert refused.record.errors.of_kind?(:speaker_public_id, :invalid)

    accepted = create_job(creating_user: @agent, speaker_public_id: speaker.public_id)
    assert_predicate accepted, :accepted?
    assert_equal speaker.public_id, accepted.value.speaker_public_id
  end

  test "source provenance must identify a task hosted by the parent conversation" do
    source = create_run_backed_turn(conversation: @conversation, acting_user: @user).agent_run
    task = runner_tool_row(source, "schedule", claimed: false, role: nil)
    accepted = create_job(source_run_public_id: source.public_id, source_task_key: task.node_key)
    assert_predicate accepted, :accepted?

    missing = create_job(source_run_public_id: source.public_id, source_task_key: "missing")
    assert_predicate missing, :invalid?
    assert missing.record.errors.of_kind?(:source_run_public_id, :invalid)

    unrelated = AgentRun.create!(workspace: @workspace, creating_user: @user, approval_mode: "bypass")
    other_task = runner_tool_row(unrelated, "schedule", claimed: false, role: nil)
    foreign = create_job(source_run_public_id: unrelated.public_id, source_task_key: other_task.node_key)
    assert_predicate foreign, :invalid?
    assert foreign.record.errors.of_kind?(:source_run_public_id, :invalid)
  end

  test "losing parent access refuses both management verbs and edits" do
    job = create_job!
    @conversation.update!(access_default: "none")
    other = users(:curator)

    assert_equal :not_authorized, Schedules::Manage.transition(job, :cancel, by: other).outcome
    assert_equal :not_authorized, Schedules::Manage.revise(job, { prompt: "Changed" }, by: other,
      expected_lock_version: job.lock_version).outcome
    assert_predicate job.reload, :active?
    assert_equal "Check the latest status.", job.prompt
  end

  private

    def create_job(creating_user: @user, **attributes)
      DatabaseClock.stub(:now, NOW) do
        Schedules::Create.call(conversation: @conversation, creating_user: creating_user, attributes: {
          name: "Status check", prompt: "Check the latest status.", provider_id: "dev", model_ref: "mock-text",
          rule: { "kind" => "interval", "every_seconds" => 60, "starts_at" => (NOW + 60).iso8601 },
        }.merge(attributes))
      end
    end

    def create_job!(**attributes)
      result = create_job(**attributes)
      assert_predicate result, :accepted?, result.outcome.to_s
      result.value
    end
end
