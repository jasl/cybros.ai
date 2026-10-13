require "support/daemon_run_helpers"

class DaemonRunVariantsTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_a_followed_manual_answer_stops_conversation_task_commands_from_reaching_the_previous_run
    events = [input_materialized_event(1, input: "cin-1", turn: "t-1"),
      event(2, "turn_status", status: "running", variant_public_id: "v-old", run_public_id: "al-old")]
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      conversation_events: -> { api.conversation_inputs.empty? ? [] : events.dup },
      variants: {
        "turn" => { "public_id" => "t-1", "inherited" => false },
        "variants" => [{ "public_id" => "v-edit", "source" => "manual", "status" => "completed",
          "active" => true, "content" => "manual answer" }],
      })
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }, sleeper: ->(_) { }), api)
    code, answer = open(daemon, { "prompt" => "answer", "model" => "dev/mock-text", "stream" => false })
    assert_equal "201", code, answer.inspect
    wait_for { store.find("c-1")&.run_public_id == "al-old" }

    daemon.context.remember(conversation_host("c-1"), workspace: "ws-1", live: false)
    assert_equal "al-old", store.find("c-1").run_public_id, "omitting the run preserves the current correlation"
    events << event(3, "turn_status", status: "failed", run_status: "needs_attention",
      variant_public_id: "v-old", run_public_id: "al-old")
    events << event(4, "turn_variant", edited: true, activated: true, variant_public_id: "v-edit")
    events << event(5, "turn_status", status: "completed", variant_public_id: "v-edit")
    run = daemon.lineage.followers.find { |candidate| candidate.public_id == "c-1" }
    wait_for { run.event_position.sequence == 5 }
    assert_nil run.snapshot.run_public_id
    assert_equal "manual answer", run.snapshot.text

    response = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: "c-1", task_key: "r1" })
    assert_equal "400", response.code, response.body
    assert_match(/no turn in flight/, JSON.parse(response.body).dig("error", "message"))
    assert_nil store.find("c-1").run_public_id
    assert_nil store.find("al-old")
    refute(api.requests.any? { |path, _| path.end_with?("/runs/al-old/tasks/r1/cancel") })
  end

  def test_context_remember_can_explicitly_clear_a_backing_run
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-old")

    daemon.context.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: nil)

    assert_nil store.find("c-1").run_public_id
    assert_equal "t-1", store.find("c-1").turn
  end

  private

    def event(sequence, type, **payload)
      { "public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}", "type" => type,
        "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-20T00:00:00Z",
        "payload" => payload.transform_keys(&:to_s).merge("turn_public_id" => "t-1") }
    end
end
