require "test_helper"

class Executors::OperationTraceTest < ActiveSupport::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!
    agent_run = seed(tool("parent", "read_file"))
    @parent = agent_run.agent_run_tasks.sole
  end

  test "snapshot pages batch sealed observations independently of page width" do
    record_observations(20)
    small, small_queries = snapshot_queries(limit: 2)
    large, large_queries = snapshot_queries(limit: 40)

    assert_equal small_queries.length, large_queries.length
    assert_equal 1, large_queries.count { |sql| sql.include?('FROM "content_bodies"') }
    assert_equal 1, large_queries.count { |sql| sql.include?('FROM "content_body_entries"') }
    assert_equal 1, large_queries.count { |sql| sql.include?('FROM "content_fragments"') }
    assert_equal 2, small.fetch("next_after")
    assert_nil large.fetch("next_after")
    assert_equal (1..40).to_a, large.fetch("trace").map { |event| event.fetch("position") }
    outcomes = large.fetch("trace").select { |event| event.fetch("type") == "observation" }
    assert_equal (0...20).map { |index| "child #{index}" }, outcomes.map { |event| event.dig("outcome", "output") }
  end

  test "an operation-only page does not read an observation body outside that page" do
    record_observations(2)
    page, queries = snapshot_queries(limit: 1)

    assert_equal ["operation"], page.fetch("trace").map { |event| event.fetch("type") }
    assert_equal 1, page.fetch("next_after")
    assert queries.none? { |sql| sql.match?(/FROM "content_(?:bodies|body_entries|fragments)"/) }
  end

  test "snapshot pages retain every observation when completion reverses acceptance order" do
    record_observations(101, reverse: true)
    events = []
    after = 0
    loop do
      page = Executors::TaskOperations::Trace.snapshot(@parent, after: after, limit: 100)
      events.concat(page.fetch("trace"))
      after = page.fetch("next_after")
      break unless after
    end

    assert_equal (1..202).to_a, events.map { |event| event.fetch("position") }
    observed = events.select { |event| event.fetch("type") == "observation" }
    assert_equal (0...101).to_a.reverse.map { |index| "op_#{index}" }, observed.map { |event| event.fetch("key") }
  end

  private

    def record_observations(count, reverse: false)
      count.times do |index|
        operation = @parent.task_operations.create!(operation_key: "op_#{index}", kind: "tool",
          request_digest: "a" * 64, request: {}, response: { "receipt" => {} },
          position: reverse ? index + 1 : index * 2 + 1,
          observed_position: reverse ? count * 2 - index : index * 2 + 2, observation: { "batch" => false, "results" => [
            { "status" => "completed", "is_error" => false, "offset" => 0, "length" => 1,
              "output_present" => true, "readable_text" => "child #{index}" },
          ] })
        stored = ContentBodies::Replace.call(owner: operation, role: "observation",
          entries: [{ "text" => "child #{index}" }], seal: true)
        assert_predicate stored, :accepted?
      end
    end

    def snapshot_queries(limit:)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] if payload[:sql].start_with?("SELECT") && !payload[:cached]
      end
      page = AgentRunTask.uncached { Executors::TaskOperations::Trace.snapshot(@parent, limit: limit) }
      [page, statements]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
