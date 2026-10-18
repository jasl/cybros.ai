require "test_helper"

class CliCostLimitTest < Minitest::Test
  include RhoTest::CliHarness

  def test_cost_limit_hold_explains_recovery_even_when_the_model_declared_absorb
    terminal, seen = cli, {}
    task = { "task_key" => "compact", "kind" => "model_task", "status" => "failed", "on_failure" => "absorb",
      "error_key" => "conversation_cost_limit_reached" }
    2.times { terminal.report_tasks({ "tasks" => [task] }, seen) }

    assert_equal 1, @out.string.scan("Raise or clear that limit").length
    assert_includes @out.string, "retry the held model task"
    assert_includes @out.string, "Changing the limit does not restart work"
  end

  def test_cost_limit_hint_excludes_resolved_running_and_non_model_tasks
    terminal = cli
    [{ "failure_resolution" => "abandoned" }, { "status" => "waiting" }, { "kind" => "tool_task" }].each do |fields|
      task = { "task_key" => "compact", "kind" => "model_task", "status" => "failed", "on_failure" => "absorb",
        "error_key" => "conversation_cost_limit_reached" }.merge(fields)
      terminal.report_tasks({ "tasks" => [task] }, {})
    end
    refute_includes @out.string, "Raise or clear that limit"
  end
end
