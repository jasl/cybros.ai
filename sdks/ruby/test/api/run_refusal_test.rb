require "test_helper"
require_relative "../support/run_fixtures"

# A STEP A PROVIDER DECLINED, as the SDK reads a task: the typed summary
# says a step was refused and what the answerer's declared fallback
# replaced, so a caller never digs a String key out of a Hash for it.
class ApiRunRefusalTest < Minitest::Test
  include CybrosAgentTest::RunFixtures

  # A REFUSED STEP FAILED with its quality and category on the summary and
  # `model_refused` as its error; the two readers ask the summary, so a
  # caller never digs a String key out of a Hash to learn a step was refused.
  def test_a_refused_task_reads_its_quality_and_category
    refused = TASK.merge(
      "status" => "failed",
      "result" => { "finish_quality" => "refused", "refusal_category" => "cyber" },
      "error" => { "key" => "model_refused", "detail" => "dev/x declined this step (cyber), so it failed with no output" },
      "completed_at" => "2026-09-02T00:01:00Z"
    )
    body = { "run" => RUN.merge("status" => "running", "tasks" => [refused]) }
    task = workspace([[200, {}, body]]).runs.run(RUN_ID).fetch.tasks.first

    assert_predicate task, :refused?
    assert_predicate task, :failed?
    assert_equal ["refused", "cyber"], [task.finish_quality, task.refusal_category]

    plain = workspace([[200, {}, { "run" => RUN }]]).runs.run(RUN_ID).fetch.tasks.first
    refute_predicate plain, :refused?
    assert_nil plain.refusal_category
    assert_nil plain.model_change
  end

  # A step the answerer's declared fallback re-ran carries what it
  # replaced from the switch on — a WAITING round with a `result` — and
  # reads no refused quality once the fallback answered.
  def test_a_switched_task_reads_what_it_replaced
    change = { "from" => "dev/primary", "reason" => "model_refused", "category" => "cyber" }
    switched = TASK.merge("status" => "waiting", "result" => { "model_change" => change })
    body = { "run" => RUN.merge("status" => "running", "tasks" => [switched]) }
    task = workspace([[200, {}, body]]).runs.run(RUN_ID).fetch.tasks.first

    assert_equal change, task.model_change
    assert_predicate task, :waiting?
    refute_predicate task, :refused?
  end
end
