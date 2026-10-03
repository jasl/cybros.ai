require "test_helper"

class AgentLoops::PrunedReplayLoadingTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
  end

  test "pruned history batches body reads as the chain grows, including absent reasoning traces" do
    small = prepare_prune(3)
    large = prepare_prune(12)

    assert_equal 1, material_read_count(small)
    assert_equal 1, material_read_count(large), "ordinary rounds need only one batched source read"

    small_queries = content_reads(compose_and_capture(small, replay: replay("all")))
    large_queries = content_reads(compose_and_capture(large, replay: replay("all")))

    assert_operator large_queries.length, :<=, small_queries.length + 2,
      "content reads must be batched, not repeated for every historical round: " \
        "#{small_queries.length} for 3 rounds, #{large_queries.length} for 12"
  end

  # A round's trace is its ORDER and its messages' labels, not replay
  # material, so it is read whatever the mode — once, batched for the whole
  # chain, never per round; the mode gates only the ladder.
  test "cleared tool outputs are not loaded, and the traces are read in one batch even with replay off" do
    round = prepare_prune(4)
    calls = round.agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ToolTask.sti_name).pluck(:id)
    queries = compose_and_capture(round, replay: replay("none"))

    output_nodes = queries.select { |query| role_read?(query, "output") }.flat_map do |query|
      attributes(query).select { |bind| bind.name == "agent_loop_node_id" }.flat_map(&:value_for_database)
    end
    assert_empty output_nodes & calls, "cleared results contribute placeholders, not output bodies or captures"
    assert_equal 1, queries.count { |query| role_read?(query, "reasoning_trace") },
      "the chain's traces load in one batched read under mode none"
  end

  private

    def material_read_count(round)
      rounds = Conversations::Compaction::Serialize.chain(round)
      count = 0
      subscriber = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        material = ApplicationRecord.uncached { AgentLoops::InputComposition.material_by_round(rounds) }
        assert_empty material
      end
      count
    end

    def prepare_prune(round_count)
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
        answering_user: @agent)
      _turn, agent_loop = materialize_loop_reply!(conversation, agent: @agent,
        text: "read the files", model_ref: "mock-windowless")
      schedule_loop!(agent_loop)

      tool_round_count = round_count - 1
      tool_round_count.times do |index|
        call_id = "read_#{index}"
        run_loop_round!(agent_loop, sse_success("reading #{index}", tool_calls: [
          { id: call_id, name: "read_file", arguments: { path: "#{index}.txt" }.to_json },
        ]))
        settled = AgentLoops::Parks::Settle.call(
          node: agent_loop.agent_loop_nodes.find_by!(tool_call_id: call_id), trusted: true,
          content: "x" * (index == tool_round_count - 1 ? 32.kilobytes : 1.kilobyte), outcome: "completed"
        )
        assert_predicate settled, :applied?
        schedule_loop!(agent_loop) unless index == tool_round_count - 1
      end

      consumer = agent_loop.agent_loop_nodes.where(type: AgentLoopNodes::ModelTask.sti_name, status: "queued").sole
      appended = AgentLoops::Tasks::Append.call(AgentLoops::Tasks::Append::Command.kernel(
        agent_loop: agent_loop, origin: "kernel", tip: kernel_tip(consumer, [consumer]),
        steps: [AgentLoops::Tasks::Step.inheriting(consumer, key: "after", prompt: "continue")]
      ))
      assert_predicate appended, :applied?
      schedule_loop!(agent_loop)
      assert_includes round_request_entries(consumer.reload).map { |entry| entry.dig("payload", "output") },
        "x" * 32.kilobytes, "even the newest large result was consumed before this prune"
      apply_via(loop_attempt(agent_loop), sse_success("Consumed all results"))
      AgentLoops::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      round = loop_node(agent_loop, "after")
      repair = Conversations::Compaction::Arm.call(agent_loop: agent_loop, node: round,
        trigger: Conversations::Compaction::Trigger.wall(round,
          overshoot: Conversations::Compaction::Overshoot.bytes(1)))
      assert_predicate repair, :pruned?
      assert_equal consumer.node_key, round.reload.pruned_before,
        "only the final consumer's short answer joins the tail, so every consumed tool result clears"
      clear_enqueued_jobs
      round
    end

    def replay(mode)
      target = ModelReasoning::ReplayLadder::Target.new(provider_id: "dev", model_id: "mock-windowless",
        reasoning_effort: nil, capability: Nexus::ReasoningReplayCapability.default)
      Conversations::ContextAssembly::Replay.new(mode: mode, target: target)
    end

    # Every SELECT the composition ran, with its binds: a body read may be
    # its own query or ride a join that starts at another table.
    def compose_and_capture(round, replay:)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        if payload.fetch(:sql).start_with?("SELECT") && !payload[:cached] && payload[:name] != "SCHEMA"
          queries << { sql: payload.fetch(:sql), binds: payload.fetch(:binds) }
        end
      end
      result = ApplicationRecord.uncached do
        AgentLoops::InputComposition.call(node: round.reload, input: round.input_value, replay: replay)
      end
      assert_predicate result, :composed?
      entries = Nexus::InputEntries.for(result.elements)
      calls = entries.select { |entry| entry["type"] == "tool_call_item" }
      results = entries.select { |entry| entry["type"] == "tool_result_item" }
      assert_equal calls.map { |entry| entry.dig("payload", "call_id") },
        results.map { |entry| entry.dig("payload", "call_id") }
      assert results.all? { |entry| entry.dig("payload", "output") == AgentLoops::RoundReplay::Pairing::CLEARED }
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def content_reads(queries)
      queries.select { |query| query.fetch(:sql).match?(/\ASELECT .*FROM "content_(?:bodies|body_entries|fragments)"/m) }
    end

    def role_read?(query, role)
      attributes(query).any? { |bind| bind.name == "role" && bind.value_for_database == role }
    end

    # Rails hands a query's binds as attributes or, for some statements, as
    # bare values; only an attribute names its column.
    def attributes(query)
      query.fetch(:binds).select { |bind| bind in ActiveModel::Attribute }
    end
end
