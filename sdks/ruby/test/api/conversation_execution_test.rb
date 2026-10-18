require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationExecutionTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_input_factory_recovers_expired_materialization_and_content_using_only_public_reads
    page = { "events" => [], "pagination" => { "next_after" => nil, "watermark" => 20 } }
    materialization = contract.fetch("valid_materialization_fixture")
    input = materialization.fetch("materialization").fetch("input_public_id")
    deck = contract.fetch("valid_variants_fixture")
    deck = deck.merge("variants" => deck.fetch("variants").map { |variant| variant.merge("source" => "inference", "run_public_id" => nil) })
    tracking = chat([[200, {}, page], [200, {}, materialization], [200, {}, deck], [200, {}, page]])
      .input_execution(input)
    assert_empty @transport.requests
    snapshot = tracking.recover

    assert_equal VARIANT_ID, tracking.result.variant
    assert_equal VARIANT_ID, snapshot.execution.variant
    assert_equal deck.fetch("variants").find { |variant| variant.fetch("public_id") == VARIANT_ID }.fetch("content"), snapshot.content
    assert_equal ["#{PATH}/events", "#{PATH}/inputs/#{input}/materialization", "#{PATH}/turns/#{TURN_ID}/variants", "#{PATH}/events"],
      @transport.requests.map { |request| request.fetch(:path) }
    assert_equal({ "include_hidden" => true }, request(1).fetch(:params))
    assert @transport.requests.all? { |request| request.fetch(:method) == :get }
    assert_equal CybrosAgent::KernelFeed::Position.start, tracking.position
  end

  def test_known_execution_factory_reads_its_exact_run_and_decisions_without_cancelling
    run_id = "019f0000-0000-7000-8000-000000000601"
    run_path = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/runs/#{run_id}"
    result = CybrosAgent::InputMaterialization::Result.new(turn: TURN_ID, variant: VARIANT_ID, run_public_id: run_id)
    deck = contract.fetch("valid_variants_fixture")
    deck = deck.merge("variants" => deck.fetch("variants").map { |variant| variant.merge("run_public_id" => run_id, "status" => "running", "content" => nil) })
    page = { "events" => [], "pagination" => { "next_after" => nil, "watermark" => 0 } }
    task = { "key" => "ask", "kind" => "await_task", "status" => "awaiting_input", "lifetime" => "conversation", "wake" => "auto" }
    run = { "run" => { "public_id" => run_id, "status" => "running",
      "attention" => { "reason" => "awaiting_human", "blocked_task_keys" => ["ask"] },
      "tasks" => [task] } }
    detail = { "task" => task.merge("prompt" => "Continue?") }
    tracking = chat([[200, {}, deck], [200, {}, page], [200, {}, run], [200, {}, run], [200, {}, detail]]).execution(result)
    assert_same tracking, tracking.refresh
    assert_empty @transport.requests
    snapshot = tracking.recover
    refute_predicate snapshot, :needs_attention?
    refute_predicate snapshot, :terminal?
    assert_equal "awaiting_human", snapshot.attention.reason
    assert_equal 3, @transport.requests.length
    decision = tracking.decisions.fetch(0)
    assert_predicate decision, :ask?
    assert_equal "Continue?", decision.prompt
    assert_equal ["#{PATH}/turns/#{TURN_ID}/variants", "#{PATH}/events", run_path, run_path, "#{run_path}/tasks/ask"],
      @transport.requests.map { |request| request.fetch(:path) }
    assert @transport.requests.all? { |request| request.fetch(:method) == :get }
  end
end
