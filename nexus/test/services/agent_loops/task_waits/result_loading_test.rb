require "test_helper"

class AgentLoops::TaskWaits::ResultLoadingTest < ActiveJob::TestCase
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "observing a completed fan batches result bodies without changing completion order or values" do
    counts = [1, 20].map do |size|
      results = Array.new(size) do |index|
        {
          key: "file-#{index}", text: "src/file_#{index}.rb: #{index + 1} lines",
          structured: [false, nil, { "lines" => index + 1 }].fetch([index, 2].min),
          is_error: index == 2,
        }
      end
      agent_loop = completed_fan(results)
      observed = nil
      queries = content_queries do
        # A fresh row and an uncached read match the scheduler's next pass.
        target = AgentLoopNode.find_by!(agent_loop_id: agent_loop.id, node_key: "files")
        observed = AgentLoops::TaskWaits::Observe.call(target)
      end

      # The data names each tip by its key alone; the text names its call too.
      assert_equal({
        "agent_loop" => agent_loop.public_id, "task" => "files", "status" => "completed",
        "results" => results.reverse.map { |result| expected_result(result) },
      }, observed.data)
      assert_equal results.reverse.map { |result|
        "<task_result task=\"#{result.fetch(:key)}\" status=\"completed\">\n" \
          "<call>read_file {\"path\":\"src/#{result.fetch(:key)}.rb\"}</call>\n#{result.fetch(:text)}\n</task_result>"
      }.join("\n\n"), observed.text
      assert_equal results.any? { |result| result.fetch(:is_error) }, observed.error
      queries
    end

    assert counts.first.values.all?(&:positive?), "the measurement must observe all three content tables"
    assert_equal counts.first, counts.last,
      "wait results need bounded content queries: 1 result #{counts.first.inspect}; 20 results #{counts.last.inspect}"
  end

  private

    def completed_fan(results)
      tools = results.map do |result|
        tool(result.fetch(:key), "read_file", "input" => { "path" => "src/#{result.fetch(:key)}.rb" })
      end
      agent_loop = seed(parallel(*tools, tool("unselected", "read_file"),
        until: results.length, losers: "run_out", key: "files"))
      started = AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: @human))
      assert_predicate started, :accepted?
      schedule_loop!(agent_loop)

      now = Time.current
      results.reverse.each_with_index do |result, index|
        travel_to(now + index.seconds) do
          settled = AgentLoops::Parks::Settle.call(
            node: loop_node(agent_loop, result.fetch(:key)), trusted: true, outcome: "completed",
            content: result.fetch(:text), structured_content: result.fetch(:structured),
            is_error: result.fetch(:is_error)
          )
          assert_predicate settled, :applied?
        end
      end
      schedule_loop!(agent_loop)
      assert_equal "completed", loop_node(agent_loop, "files").status
      assert_equal "dispatched", loop_node(agent_loop, "unselected").status
      agent_loop
    end

    def expected_result(result)
      {
        "task" => result.fetch(:key), "status" => "completed", "is_error" => result.fetch(:is_error),
        "output" => result.fetch(:text), "content" => [{ "type" => "text", "text" => result.fetch(:text) }],
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
