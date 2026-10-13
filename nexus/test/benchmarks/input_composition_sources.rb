require "test_helper"

class InputCompositionSourcesBenchmark < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  test "measure source selection over short and full authored material windows" do
    [1, 32].each do |width|
      agent_run = seed(model("prior"),
        *Array.new(width) { |index| tool("material-#{index}", "read_file") }, model("reader"))
      reader = agent_run.agent_run_tasks.find_by!(node_key: "reader")
      queries = 0
      records = 0
      query_subscriber = lambda do |*, payload|
        queries += 1 unless payload[:cached] || payload[:name] == "SCHEMA"
      end
      record_subscriber = ->(*, payload) { records += payload.fetch(:record_count) }
      sources = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications.subscribed(query_subscriber, "sql.active_record") do
        ActiveSupport::Notifications.subscribed(record_subscriber, "instantiation.active_record") do
          ApplicationRecord.uncached do
            sources = AgentRuns::InputComposition.sources_for(reader)
          end
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_equal width + 1, sources.length
      puts({ width: width, queries: queries, records: records, elapsed_ms: (elapsed * 1000).round(3) }.to_json)
    end
  end
end
