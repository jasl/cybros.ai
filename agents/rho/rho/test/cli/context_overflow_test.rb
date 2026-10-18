require "test_helper"

class CliContextOverflowTest < Minitest::Test
  include RhoTest::CliHarness

  def test_an_unresolved_overflow_explains_model_limits_once_when_the_failure_arrives
    terminal, seen = cli, {}
    task = { "task_key" => "r1", "kind" => "model_task", "status" => "waiting", "on_failure" => "halt" }
    terminal.report_tasks({ "tasks" => [task] }, seen)
    refute_includes @out.string, "Context and capabilities"

    task.merge!("status" => "failed", "error_key" => "provider_context_overflow", "error_detail" => "private upstream body")
    2.times { terminal.report_tasks({ "tasks" => [task] }, seen) }

    assert_equal 1, @out.string.scan("Context and capabilities").length
    assert_includes @out.string, "Nexus Settings > Model providers > Edit model > Context and capabilities"
    assert_includes @out.string, "Combined context window"
    assert_includes @out.string, "Input token limit or Combined context window"
    assert_includes @out.string, "server's actual limit (use only one)"
    assert_includes @out.string, "Output token limit"
    assert_includes @out.string, "lower the requested output budget"
    refute_includes @out.string, "private upstream body"
  end

  def test_context_recovery_does_not_prompt_for_settled_or_nonfailed_tasks
    terminal = cli
    [{ "status" => "waiting" }, { "status" => "completed" },
      { "failure_resolution" => "abandoned" }, { "on_failure" => "absorb" }].each do |fields|
      terminal.report_tasks({ "tasks" => [{ "task_key" => "r1", "status" => "failed",
        "error_key" => "provider_context_overflow" }.merge(fields)] }, {})
    end
    refute_includes @out.string, "Context and capabilities"

    seen = {}
    terminal.report_tasks({ "tasks" => [{ "task_key" => "r2", "status" => "waiting", "on_failure" => "absorb" }] }, seen)
    terminal.report_tasks({ "tasks" => [{ "task_key" => "r2", "status" => "failed", "error_key" => "provider_context_overflow" }] }, seen)
    refute_includes @out.string, "Context and capabilities", "partial pushed frames retain the authored absorb policy"
  end
end
