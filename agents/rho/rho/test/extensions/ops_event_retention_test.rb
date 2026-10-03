require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsEventRetentionTest < Minitest::Test
  include RhoTest::OpsHarness

  # The hosted event window may be empty after 30 days while the completed
  # turn and its loop remain readable. Serve ordinary public documents through
  # the real SDK so recovery cannot depend on replay evidence still existing.
  def test_attaching_a_conversation_recovers_a_completed_turn_after_its_events_expired
    api = retained_history_api
    daemon = member_ready(boot(realtime_factory: ->(_credential) { nil }), api)
    assert_retained_history_readable(daemon)

    response = request(daemon, :post, "/loops/attach", token: bearer(daemon),
      body: { public_id: "c-7", host_type: "conversation", stream: false })

    assert_equal "200", response.code, response.body
    assert_recovered(daemon, api)
  end

  def test_readoption_recovers_a_completed_turn_after_its_events_expired
    api = retained_history_api
    daemon = member_ready(boot(realtime_factory: ->(_credential) { nil }), api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-7"),
      workspace: "ws-1", turn: "t-7", loop: "al-7")
    assert_retained_history_readable(daemon)

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_recovered(daemon, api)
  end

  private

    def retained_history_api
      variant = {
        "public_id" => "v-7", "source" => "agent_loop", "status" => "completed",
        "content" => "The retained answer.", "content_preview" => "The retained answer.",
        "agent_loop_public_id" => "al-7", "active" => true,
      }
      turn = {
        "public_id" => "t-7", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => "0199-user", "created_at" => "2026-08-01T00:00:00Z",
        "active_variant" => variant,
      }
      trace = NexusDoubles::RUNNING_TRACE.merge(
        "public_id" => "al-7", "status" => "completed",
        "created_at" => "2026-08-01T00:00:00Z", "updated_at" => "2026-08-01T00:01:00Z",
        "tasks" => NexusDoubles::RUNNING_TRACE.fetch("tasks").map { |task| task.merge("status" => "completed") },
        "turn" => { "status" => "completed", "public_id" => "t-7", "conversation_public_id" => "c-7" }
      )
      NexusDoubles::FakeAgentApi.new(trace: trace, turns: [turn], conversation_events: [], conversation_event_head: 42,
        variants: { "turn" => { "public_id" => "t-7", "inherited" => false }, "variants" => [variant] })
    end

    def assert_retained_history_readable(daemon)
      workspace = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1")
      conversation = workspace.conversations.conversation("c-7")
      refute conversation.fetch.busy?
      assert_equal "completed", conversation.turns.list.items.fetch(0).status
      assert_equal "The retained answer.", conversation.turns.variants("t-7").active.content
      assert_equal "completed", workspace.agent_loop("al-7").fetch.status
      page = conversation.events
      assert_empty page.items
      assert_nil page.next_after
      assert_equal 42, page.watermark, "the committed head survives expiration of replay items"
    end

    def assert_recovered(daemon, api)
      run = daemon.lineage.runs.find { |candidate| candidate.public_id == "c-7" }
      refute_nil run
      # The first read above proved the public fixture. Wait until the real
      # follower has read the empty window twice, including its next poll.
      wait_for { api.requests.count { |path, _| path.end_with?("/conversations/c-7/events") } >= 3 }

      snapshot = run.snapshot
      assert_equal "completed", snapshot.status,
        "expired replay evidence must not leave a durable completed turn pending forever"
      assert snapshot.complete
      assert run.turn_settled?, "a reader must finish although no old terminal event can replay"
      assert_equal ["t-7", "al-7"], [snapshot.turn, snapshot.loop]
      assert_equal [["work", "completed"]], snapshot.tasks.map { |task| [task.task_key, task.status] }
      assert_equal "The retained answer.", snapshot.text
      refute run.settled?, "the conversation remains followed for future turns"
      assert_equal ["c-7"], store.rows.map(&:host_public_id)
    end
end
