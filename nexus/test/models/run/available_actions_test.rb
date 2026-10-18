require "test_helper"
require_relative "../../test_helpers/awaits_test_helper"

class Run::AvailableActionsTest < ActiveJob::TestCase
  include AwaitsTestHelper

  test "attention applies the same answer and failure rules before pagination" do
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    question = ask_through_the_model!(run)
    authored = seed(ask("private"))
    start!(authored)
    actions = Run::AvailableActions.new(run: run.reload, user: @human)
    assert actions.answer?(question)
    assert_includes attention_ids, question.id
    assert_not_includes attention_ids, authored.tasks.sole.id
    question.update!(await_started_at: 2.days.ago)
    assert_not Run::AvailableActions.new(run: run, user: @human).answer?(question)
    assert_not_includes attention_ids, question.id
  end

  test "paused park deadlines use the frozen run clock and pruned runs have no actions" do
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    question = ask_through_the_model!(run)
    Runs::Pause.call(Runs::Pause::Command.graceful(run: run.reload, acting_user: @human))
    travel 2.days do
      assert Run::AvailableActions.new(run: run.reload, user: @human).answer?(question)
      assert_includes attention_ids, question.id
    end
    run.update!(details_pruned_at: Time.current)
    assert_not Run::AvailableActions.new(run: run, user: @human).answer?(question)
    assert_not_includes attention_ids, question.id
  end

  private

    def attention_ids
      Run::AvailableActions.attention_tasks(runs: Run.writable_by(@human)).pluck(:id)
    end
end
