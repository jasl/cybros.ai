require "support/daemon_loop_helpers"

class DaemonLoopViewStateTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_undo_clears_persisted_turn_and_loop_without_forgetting_the_conversation
    events = [input_materialized_event(1, input: "cin-1", turn: "t-1"),
      event(2, "turn_status", status: "completed", loop_status: "completed",
        variant_public_id: "v-old", agent_loop_public_id: "al-old")]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      conversation_events: -> { api.conversation_inputs.empty? ? [] : events.dup })
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }, sleeper: ->(_) { }), api)
    code, answer = open(daemon, { "prompt" => "answer", "model" => "dev/mock-text", "stream" => false })
    assert_equal "201", code, answer.inspect
    wait_for { store.find("c-1")&.loop == "al-old" }

    daemon.context.remember(conversation_host("c-1"), workspace: "ws-1", live: false)
    assert_equal "t-1", store.find("c-1").turn, "omission preserves both correlation fields"
    assert_equal "al-old", store.find("c-1").loop

    events << event(3, "turn_deleted", position: 1)
    run = daemon.lineage.runs.find { |candidate| candidate.public_id == "c-1" }
    wait_for { run.event_position.sequence == 3 }
    assert_nil store.find("c-1").turn
    assert_nil store.find("c-1").loop
    assert_nil store.find("al-old")
    assert_includes daemon.lineage.runs, run

    response = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "c-1", task_key: "r1" })
    assert_equal "400", response.code, response.body
    assert_match(/no turn in flight/, JSON.parse(response.body).dig("error", "message"))
    refute(api.requests.any? { |path, _| path.end_with?("/agent_loops/al-old/tasks/r1/cancel") })
  end

  private

    def event(sequence, type, **payload)
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-20T00:00:00Z",
        "payload" => payload.transform_keys(&:to_s).merge("turn_public_id" => "t-1") }
    end
end
