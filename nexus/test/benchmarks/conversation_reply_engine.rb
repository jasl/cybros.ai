require "test_helper"

# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/conversation_reply_engine.rb
# Compares the two existing engines with identical input, configuration and fake HTTP.
# Timings cover domain work through an idle, completed conversation, excluding fixture
# setup, checks, queue delivery latency and execution of broadcast/other wake jobs.
# HISTORY_TURNS=20 repeats the comparison after twenty completed replies.
# GLOBAL_CONVERGENCE=1 compares the periodic sweeps with targeted completion.
# Rollback transactions defer enqueue callbacks: queue work/counts are not measured.
# SQL instrumentation overhead is included equally in both lanes.
# Every sample rolls back; the override exists only in this explicit benchmark.
class ConversationReplyEngineBenchmark < ActiveJob::TestCase
  include InvocationHarness

  class RunReply < Conversations::Inputs::ApplyNext
    private

      def materialize_head(input, selection, normalized, history)
        materialize_loop(input, selection, normalized.value.value, normalized.value.uploads, history)
      end
  end

  TABLES = %w[
    agent_runs agent_run_tasks agent_run_edges agent_run_append_receipts
    conversation_inputs conversation_turns conversation_turn_variants
    conversation_events conversation_event_items conversation_event_cursors
    content_bodies content_body_entries content_fragments
    model_invocations model_invocation_attempts usage_records model_usage_summaries
  ].freeze
  WARMUPS = 2
  SAMPLES = Integer(ENV.fetch("SAMPLES", "10"))
  HISTORY_TURNS = Integer(ENV.fetch("HISTORY_TURNS", "0"))
  GLOBAL_CONVERGENCE = ENV["GLOBAL_CONVERGENCE"] == "1"

  setup do
    @account, @human, @agent = accounts(:cybros), users(:member), users(:agent)
    DevModelLane.ensure_enabled!(@account)
    # Both lanes carry the same explicit mode because today's loop requires one,
    # even without tools. This does not measure a future nil-mode implementation.
    @agent.update!(approval_mode: "bypass", tool_definitions: nil, lifecycle_hooks: nil)
  end

  test "compare ordinary direct replies with a single model task loop" do
    samples = { direct: [], loop: [] }
    histories = samples.keys.to_h do |engine|
      conversation = Conversation.create!(workspace: workspaces(:shared),
        creating_user: @human, answering_user: @agent)
      HISTORY_TURNS.times { complete_reply(conversation, engine) }
      [engine, conversation]
    end
    expected_request = nil
    (WARMUPS + SAMPLES).times do |index|
      order = index.even? ? %i[direct loop] : %i[loop direct]
      order.each do |engine|
        sample, request = run_sample(engine, histories.fetch(engine))
        expected_request ||= request
        assert_equal expected_request, request, "both engines must send identical provider input"
        samples.fetch(engine) << sample if index >= WARMUPS
      end
    end
    samples.each do |engine, measurements|
      puts JSON.generate(operation: "conversation_reply_engine", engine: engine,
        warmups: WARMUPS, history_turns: HISTORY_TURNS,
        convergence: GLOBAL_CONVERGENCE ? "global" : "targeted", samples: measurements)
    end
  end

  private

    def run_sample(engine, conversation)
      sample = request = nil
      ApplicationRecord.transaction(requires_new: true) do
        conversation.reload
        sample, request = complete_reply(conversation, engine)
        raise ActiveRecord::Rollback
      end
      clear_enqueued_jobs
      [sample, request]
    end

    def complete_reply(conversation, engine)
      accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: conversation, acting_user: @human, kind: "direct_reply", role: "user",
        entries: [{ "text" => "Reply briefly to this ordinary chat message." }],
        visible_in_context: true, delivery_mode: "queue", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil,
        provider_id: "dev", model_ref: "mock-text", reasoning_effort: nil, request_options: nil
      ))
      assert_predicate accepted, :accepted?
      clear_enqueued_jobs
      before_rows = row_counts
      before_events = conversation.conversation_event_items.group(:item_type).count
      expected_revision = conversation.reload.context_revision + 1
      stages = {}
      GC.start

      materializer = engine == :loop ? RunReply : Conversations::Inputs::ApplyNext
      turn = nil
      stages[:materialize] = measure do
        result = materializer.call(conversation_id: conversation.id)
        raise "materialization refused: #{result.outcome}" unless result.accepted?

        turn = result.value
      end
      materialized_rows = row_counts
      variant = turn.active_variant
      agent_run = variant.agent_run
      if engine == :loop
        assert_not_nil agent_run
        assert_equal 1, agent_run.agent_run_tasks.count
        stages[:schedule_initial] = measure { AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) }
      else
        assert_nil agent_run
      end

      admitted = nil
      stages[:admit] = measure { admitted = ModelInvocations::AdmitQueuedWork.call.admitted.sole }
      invocation = admitted.invocation
      assert_equal(agent_run ? agent_run.id : conversation.id,
        agent_run ? invocation.agent_run_id : invocation.conversation_id)
      request = nil
      fake_dispatch(sse_success("the reply")) do |adapter|
        stages[:execute] = measure { ModelInvocations::RunJob.perform_now(admitted.attempt.public_id) }
        request = adapter.requests.sole.fetch(:body)
      end
      assert_equal conversation.public_id, JSON.parse(request).fetch("prompt_cache_key")
      # The histories belong to different conversations. Compare all remaining
      # serialized bytes, including their order, after replacing only this identity.
      request = request.sub("\"prompt_cache_key\":#{conversation.public_id.to_json}",
        '"prompt_cache_key":"conversation"')
      assert_equal "completed", invocation.reload.status
      terminal_invocation_id = invocation.id unless GLOBAL_CONVERGENCE

      if agent_run
        stages[:converge_task] = measure do
          AgentRuns::ConvergeTerminalSteps.call(invocation_id: terminal_invocation_id)
        end
        stages[:schedule_final] = measure { AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) }
        assert_equal "completed", agent_run.reload.status
        assert_equal "completed", agent_run.agent_run_tasks.sole.status
      end
      stages[:converge_turn] = measure do
        Conversations::Turns::Converge.call(conversation_id: conversation.id,
          agent_run_id: agent_run&.id, invocation_id: agent_run ? nil : terminal_invocation_id)
      end
      stages[:drain_inputs] = measure { Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id) }
      assert_equal "completed", turn.reload.status
      assert_equal "completed", variant.reload.status
      assert_equal "Mock: the reply", variant.content_bodies.find_by!(role: "content").effective_text
      assert_nil conversation.reload.active_turn_id
      assert_equal expected_revision, conversation.context_revision
      assert_equal 0, conversation.conversation_inputs.count
      assert_not_nil invocation.reload.terminal_event_recorded_at

      sample = {
        elapsed_ms: stages.values.sum { |stage| stage.fetch(:elapsed_ms) }.round(3),
        stages: stages,
        materialized_rows: row_delta(before_rows, materialized_rows),
        completed_rows: row_delta(before_rows, row_counts),
        events: row_delta(before_events, conversation.conversation_event_items.group(:item_type).count),
      }
      [sample, request]
    end

    def row_counts
      connection = ApplicationRecord.lease_connection
      TABLES.to_h { |table| [table, connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(table)}")] }
    end

    def row_delta(before, after)
      after.to_h { |table, count| [table, count - before.fetch(table, 0)] }.reject { |_, count| count.zero? }
    end

    def measure
      sql = Hash.new(0)
      sql_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].in?(%w[SCHEMA CACHE]) || payload[:cached]

        verb = payload.fetch(:sql).lstrip.split(/\s+/, 2).first.upcase
        sql[verb] += 1
      end
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ApplicationRecord.uncached { yield }
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
      { elapsed_ms: elapsed_ms.round(3), allocations: GC.stat(:total_allocated_objects) - allocated,
        sql: sql }
    ensure
      ActiveSupport::Notifications.unsubscribe(sql_subscriber)
    end
end
