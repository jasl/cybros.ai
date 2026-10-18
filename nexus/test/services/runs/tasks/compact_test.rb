require "test_helper"
require_relative "../../../test_helpers/compaction_test_helper"

class Runs::Tasks::CompactTest < ActiveJob::TestCase
  include CompactionTestHelper

  test "candidate reads do not render history, lock, write or start model work" do
    run = loop_at_the_wall(bulk: "the work so far")
    round = node(run, "round2")
    clear_enqueued_jobs
    queries = []
    capture = ->(*, payload) { queries << payload.fetch(:sql) }

    Conversations::Compaction::Serialize.stub(:loop_entries, ->(*) { flunk "eligibility rendered history" }) do
      ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { flunk "eligibility started provider IO" }) do
        assert_no_enqueued_jobs do
          ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
            assert_nil refusal(run, round)
          end
        end
      end
    end

    assert_empty queries.grep(/\b(?:INSERT|UPDATE|DELETE|FOR\s+(?:SHARE|KEY\s+SHARE))\b/i)
    assert_empty queries.grep(/"content_(?:bodies|body_entries|fragments)"/)
  end

  test "an eligible empty round is refused only on submission without creating work" do
    run = queued_run
    round = node(run, "round")
    assert_nil refusal(run, round)

    assert_no_difference ["Task.count", "ModelInvocation.count"] do
      assert_no_enqueued_jobs do
        assert_equal :nothing_to_compact, compact(run, round.node_key).outcome
      end
    end
  end

  test "candidate states match the command's adjudicable run and queued model requirements" do
    run = queued_run
    round = node(run, "round")
    %w[running paused needs_attention].each do |status|
      run.status = status
      assert_nil refusal(run, round), status
    end
    %w[pending canceling completed canceled].each do |status|
      run.status = status
      assert_equal :not_adjudicable, refusal(run, round), status
    end
    run.status = "running"
    %w[running completed failed timed_out canceled skipped].each do |status|
      round.status = status
      assert_equal :task_not_queued, refusal(run, round), status
    end

    non_model = run.tasks.build(type: Tasks::ToolTask.sti_name, node_key: "tool")
    assert_equal :not_compactable, refusal(run, non_model)
    assert_equal :task_not_found, refusal(run, nil)
    run.tombstoned_at = Time.current
    assert_equal :not_found, refusal(run, nil)
  end

  test "read standing precedes task lookup and an overridden run remains inadjudicable" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent, access_default: "read")
    seam = create_run_backed_turn(conversation: conversation, acting_user: @agent)
    run = seam.run
    assert_equal :not_authorized, refusal(run, nil)
    assert_equal :not_authorized, compact(run, "missing").outcome

    conversation.conversation_access_entries.create!(user: @human, level: "full")
    assert_equal :task_not_found, refusal(run, nil)
    assert_equal :task_not_found, compact(run, "missing").outcome

    replacement = seam.turn.variants.create!(account: @account, position: 1,
      status: "completed", source: "inference")
    seam.turn.update!(active_variant: replacement)
    run.reload
    assert_equal :not_adjudicable, refusal(run, nil)
    assert_equal :not_adjudicable, compact(run, "missing").outcome
  end

  test "off and raw policies retain their refusals while raw delegation remains a candidate" do
    disabled = queued_run(compaction: { "mode" => "off" }, prompt_mechanism: "raw")
    assert_equal :compaction_disabled, refusal(disabled, node(disabled, "round"))
    assert_equal :compaction_disabled, compact(disabled, "round").outcome

    raw = queued_run(prompt_mechanism: "raw")
    assert_equal :compaction_unavailable_under_raw, refusal(raw, node(raw, "round"))
    assert_equal :compaction_unavailable_under_raw, compact(raw, "round").outcome

    delegated = queued_run(compaction: { "mode" => "delegate", "tool_name" => "my_compactor" },
      prompt_mechanism: "raw", creating_user: @agent)
    assert_nil refusal(delegated, node(delegated, "round"))
    assert_equal :nothing_to_compact, compact(delegated, "round").outcome
  end

  test "a manual repair removes the candidate and repeated submission creates no second summary" do
    run = loop_at_the_wall(bulk: "the work so far")
    round = node(run, "round2")
    assert_nil refusal(run, round)
    result = compact(run, round.node_key)
    assert_predicate result, :accepted?
    assert_equal result.summary_task_key, round.reload.compaction.fetch(Tasks::ModelTask::SUMMARY_SOURCE)
    assert_equal :already_compacted, refusal(run, round)
    clear_enqueued_jobs

    assert_no_difference "Task.count" do
      assert_no_enqueued_jobs do
        assert_equal :already_compacted, compact(run, round.node_key).outcome
      end
    end
  end

  test "submission rechecks a candidate after its queued request starts" do
    run = queued_run
    round = node(run, "round")
    assert_nil refusal(run, round)
    schedule_loop!(run)
    assert_equal "running", node(run, round.node_key).status

    assert_no_difference "Task.count" do
      assert_equal :task_not_queued, compact(run, round.node_key).outcome
    end
  end

  private

    def queued_run(compaction: nil, creating_user: @human, **shell)
      run = seed(model("round", "compaction" => compaction), creating_user: creating_user, **shell)
      result = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: creating_user))
      assert_predicate result, :accepted?
      clear_enqueued_jobs
      run
    end

    def refusal(run, round)
      Runs::Tasks::Compact.refusal_for(run: run, node: round, acting_user: @human)
    end
end
