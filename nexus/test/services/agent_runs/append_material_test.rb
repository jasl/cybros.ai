require "test_helper"

# NOTHING CARRIES ACROSS APPENDS BY POSITION: an authored envelope reads the rows it names, whatever
# earlier envelopes placed, and a waited head reads what no step of its envelope read. What remains
# to pin is the cost: the dependency bound is the only bound a long chain meets, and the head's
# unread set is read off the compiled envelope rather than a query per tip.
class AgentRuns::AppendMaterialTest < ActiveSupport::TestCase
  Append = AgentRuns::Tasks::Append
  Compile = AgentRuns::Tasks::Compile
  Step = AgentRuns::Tasks::Step

  setup do
    @workspace = workspaces(:shared)
    @human = users(:member)
  end

  test "a tool-only chain has no cumulative ceiling; a reader naming past the dependency bound is refused" do
    agent_run = seed(*Array.new(40) { |index| tool("first-#{index}") })
    grow!(agent_run, *Array.new(40) { |index| tool("next-#{index}") })
    earlier = Array.new(40) { |index| "first-#{index}" }
    bound = Compile::MAX_DEPENDENCIES_PER_TASK

    result = grow(agent_run, model("summary", "results" => earlier.first(bound)))
    assert_equal :invalid_steps, result.outcome
    assert_equal "too_many_dependencies", result.errors.sole.fetch("code"),
      "the names and the tip's own wait past the bound"
    refute agent_run.agent_run_tasks.exists?(node_key: "summary")

    grow!(agent_run, model("summary", "results" => earlier.first(bound - 1)))
    summary = node(agent_run, "summary")
    assert_equal earlier.first(bound - 1), summary.result_from_node_keys
    assert_nil summary.input_from_node_keys, "the chain behind the tip is read only by name"
  end

  test "the waited head's unread set costs no query per tip" do
    costs = [1, 32].map do |count|
      headed = splice_queries(count, head: true)
      headed - splice_queries(count, head: false)
    end
    assert_equal costs.first, costs.last
  end

  private

    def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

    # A round waiting on a composed chain of `count` tools, or the same chain with no head: the
    # difference is what the splice costs.
    def splice_queries(count, head:)
      agent_run = seed(model("seed"))
      seed_node = node(agent_run, "seed")
      seed_node.update_columns(status: "completed", completed_at: Time.current)
      kernel(agent_run, [Step::Parallel.new(members: [Step::Tool.new(key: "call", name: "wait", tool_call_id: "c")]),
                          Step.inheriting(seed_node, key: "next")], kernel_tip(seed_node, [seed_node], [], "round"))
      call = node(agent_run, "call")
      tools = Array.new(count) { |index| Step::Tool.new(key: "call-tool-#{index}", name: "read_file") }
      queries = 0
      subscriber = ->(*, payload) { queries += 1 unless payload[:cached] || payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        ApplicationRecord.uncached do
          kernel(agent_run, tools, kernel_tip(nil, [call], [], "branch"), expansion_parent: call,
            head: ("next" if head))
        end
      end
      if head
        assert_equal ["seed", "call", *tools.map(&:key)], node(agent_run, "next").input_from_node_keys,
          "the head reads every tip no step read"
      end
      queries
    end

    def kernel(agent_run, steps, tip, **command)
      result = Append.call(Append::Command.kernel(agent_run: agent_run, steps: steps, tip: tip, origin: "model",
        **command))
      assert_predicate result, :applied?, "#{result.outcome}: #{result.errors.inspect}"
    end
end
