require "test_helper"

class AgentLoops::Scripts::ResultLoadingTest < ActiveJob::TestCase
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a script batches selected result bodies while preserving their order and values" do
    counts = [1, 20].map do |size|
      results = Array.new(size) do |index|
        structured = [false, nil, { "lines" => index + 1 }].fetch([index, 2].min)
        {
          key: "file-#{index}", text: "src/file_#{index}.rb: #{index + 1} lines",
          structured: structured, is_error: index == 2,
        }
      end
      node = ready_script(results)

      queries = content_queries do
        # The job reloads the task by identity, as a separate worker does;
        # setup's associations and query cache cannot supply its results.
        AgentLoops::ScriptJob.perform_now(node.id, node.execution_generation)
      end

      assert_equal "completed", node.reload.status
      assert_equal results.reverse.map { |result| expected_result(result) },
        AgentLoops::TaskResultProjection.call(node).fetch("structured_content")
      queries
    end

    assert counts.first.values.all?(&:positive?), "the measurement must observe all three content tables"
    assert_equal counts.first, counts.last,
      "selected results need bounded content queries: 1 result #{counts.first.inspect}; 20 results #{counts.last.inspect}"
  end

  private

    def ready_script(results)
      tools = results.map { |result| tool(result.fetch(:key), "read_file", "input" => { "path" => "src/#{result.fetch(:key)}.rb" }) }
      agent_loop = seed(parallel(*tools),
        { "script" => { "key" => "select", "script" => "return results;",
          "results" => results.reverse.map { |result| result.fetch(:key) } } },
        model("report"))
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      assert_predicate started, :accepted?
      schedule_loop!(agent_loop)

      results.each do |result|
        settled = AgentLoops::Parks::Settle.call(
          node: loop_node(agent_loop, result.fetch(:key)), trusted: true, outcome: "completed",
          content: result.fetch(:text), structured_content: result.fetch(:structured),
          is_error: result.fetch(:is_error)
        )
        assert_predicate settled, :applied?
      end
      schedule_loop!(agent_loop)
      loop_node(agent_loop, "select").tap { |node| assert_equal "running", node.status }
    end

    def expected_result(result)
      {
        "status" => "completed", "is_error" => result.fetch(:is_error),
        "output" => result.fetch(:text),
        "content" => [{ "type" => "text", "text" => result.fetch(:text) }],
        "structured_content" => result.fetch(:structured), "error" => nil,
      }
    end

    def content_queries
      counts = %w[content_bodies content_body_entries content_fragments].index_with { 0 }
      observer = lambda do |*, payload|
        next if payload[:cached]

        table = payload.fetch(:sql)[/\ASELECT .*?FROM "(content_bodies|content_body_entries|content_fragments)"/m, 1]
        counts[table] += 1 if table
      end
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
        ApplicationRecord.uncached { yield }
      end
      counts
    end
end
