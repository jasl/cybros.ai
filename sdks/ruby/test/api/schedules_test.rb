require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiSchedulesTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def jobs_contract = CybrosAgentTest::ContractFixtures.pack("schedules.json")
  def row = jobs_contract.fetch("valid_fixture").fetch("schedule")

  def execution
    jobs_contract.fetch("valid_executions_fixture").fetch("executions").first.merge(
      "turn_public_id" => nil, "run_public_id" => nil, "status" => "pending")
  end

  def test_create_freezes_the_resource_intent_with_an_idempotency_key_and_typed_result
    attributed = row.merge("source_run_public_id" => "run-1", "source_task_key" => "r1t1")
    created = chat([[201, { "Idempotency-Replayed" => "true" }, { "schedule" => attributed }]]).schedules.create(
      prompt: "Report progress", rule: row.fetch("rule"), model: row.dig("model", "model"),
      reasoning_enabled: true, reasoning_effort: "medium",
      idempotency_key: "job-intent", to: "agent-1", source_run_public_id: "run-1", source_task_key: "r1t1")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/schedules", request.fetch(:path)
    assert_equal "job-intent", request.fetch(:headers).fetch("Idempotency-Key")
    body = request.fetch(:body).fetch("schedule")
    assert_equal row.fetch("rule"), body.fetch("rule")
    assert_equal row.fetch("model"), body.fetch("model")
    assert_equal "agent-1", body.fetch("answering_user_public_id")
    assert_equal %w[run-1 r1t1], body.values_at("source_run_public_id", "source_task_key")
    refute body.key?("name")
    assert_predicate created, :replayed?
    assert_equal row.fetch("public_id"), created.public_id
    assert_equal "Asia/Shanghai", created.schedule.rule.time_zone
    assert_equal row.dig("model", "model"), created.schedule.model.model
    assert_equal "run-1", created.schedule.source_run_public_id
    assert_equal attributed, JSON.parse(JSON.generate(created.schedule.to_h))
    %w[conversation_public_id creating_user_public_id created_at updated_at].each do |field|
      assert_equal row.fetch(field), created.schedule.public_send(field)
    end
  end

  def test_update_preserves_nil_versus_omission_and_requires_the_observed_version
    chat([[200, {}, { "schedule" => row }]]).schedules.update("job-1", expected_lock_version: 3, name: nil, tool_names: [])
    assert_equal :patch, request.fetch(:method)
    assert_equal({ "expected_lock_version" => 3, "name" => nil, "tool_names" => [] }, request.fetch(:body).fetch("schedule"))
    jobs = chat([[409, {}, { "error" => { "code" => "stale_object", "message" => "Job changed" } }]]).schedules
    assert_raises(CybrosAgent::Error) { jobs.update("job-1", expected_lock_version: 2, prompt: "Edited") }
    assert_equal 1, @transport.requests.length, "a stale mutation is never automatically retried"
  end

  def test_list_commands_and_execution_tail_have_distinct_pagination_and_status
    page = chat([[200, {}, { "schedules" => [row], "pagination" => { "next_after" => "jobs-next" } }]])
      .schedules.list(after: "previous", limit: 2)
    assert_equal "jobs-next", page.next_after
    assert_equal({ "after" => "previous", "limit" => 2 }, request.fetch(:params))
    %w[pause resume cancel].each do |operation|
      result = chat([[200, {}, { "schedule" => row }]]).schedules.public_send(operation, "job-1")
      assert_equal row.fetch("public_id"), result.public_id
      assert_equal :post, request.fetch(:method)
      assert_equal "#{PATH}/schedules/job-1/#{operation}", request.fetch(:path)
    end
    job = chat([[200, {}, { "schedule" => row.merge("status" => "completed", "last_execution" => execution) }]])
      .schedules.fetch("job-1")
    assert_equal "completed", job.status
    assert_equal "pending", job.last_execution.status, "a spent schedule says nothing about execution completion"
    executions = chat([[200, {}, { "executions" => [execution], "pagination" => { "next_after" => nil, "last_cursor" => "execution-1" } }]])
      .schedules.executions("job-1", after: "tail", limit: 5)
    assert_equal "execution-1", executions.last_cursor
    assert_nil executions.next_after
    assert_equal execution.fetch("child_conversation_public_id"), executions.items.first.child_conversation_public_id
    assert_nil executions.items.first.run_public_id
    assert_equal({ "after" => "tail", "limit" => 5 }, request.fetch(:params))
    empty = chat([[200, {}, { "executions" => [], "pagination" => { "next_after" => nil, "last_cursor" => "execution-1" } }]])
      .schedules.executions("job-1", after: "execution-1")
    assert_empty empty.items
    assert_equal "execution-1", empty.last_cursor
  end

  def test_unknown_status_and_rule_words_remain_inspectable
    status = chat([[200, {}, jobs_contract.fetch("unknown_status_fixture")]]).schedules.fetch("job-1")
    rule = chat([[200, {}, jobs_contract.fetch("unknown_rule_fixture")]]).schedules.fetch("job-1")
    assert_equal "zz_unknown_value", status.status
    assert_equal "zz_unknown_value", rule.rule.kind
  end
end
