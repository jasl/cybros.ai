require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsAttachVariantsTest < Minitest::Test
  include RhoTest::OpsHarness

  def test_attaching_a_conversation_replays_the_selected_candidate_with_its_run_context
    assert_attached_selection(public_id: "c-7", host_type: "conversation")
  end

  def test_attaching_through_an_old_run_follows_the_conversations_selected_run
    assert_attached_selection(public_id: "al-old")
  end

  private

    def assert_attached_selection(**body)
      trace = NexusDoubles::RUNNING_TRACE.merge("public_id" => "al-selected",
        "turn" => { "status" => "completed", "public_id" => "t-1", "conversation_public_id" => "c-7" })
      api = NexusDoubles::FakeAgentApi.new(trace: trace, conversation_events: selection_events,
        variants: {
          "turn" => { "public_id" => "t-1", "inherited" => false },
          "variants" => [{ "public_id" => "v-selected", "source" => "run", "status" => "completed",
            "content" => "selected answer", "active" => true, "run_public_id" => "al-selected" }],
        })
      daemon = member_ready(boot, api)

      response = request(daemon, :post, "/followers/attach", token: bearer(daemon), body: body)
      assert_equal "200", response.code, response.body
      run = daemon.lineage.followers.find { |candidate| candidate.public_id == "c-7" }
      refute_nil run
      wait_for { run.event_position.sequence == 3 }

      assert_equal "al-selected", run.snapshot.run_public_id
      assert_equal "selected answer", run.snapshot.text
      assert_equal "completed", run.snapshot.status
      row = host_store(daemon).find("c-7")
      assert_equal ["t-1", "al-selected"], [row.turn, row.run_public_id]
    end

    def selection_events
      [
        ["turn_status", { "status" => "completed", "variant_public_id" => "v-old", "run_public_id" => "al-old" }],
        ["turn_variant", { "activated" => true, "variant_public_id" => "v-selected", "run_public_id" => "al-selected" }],
        ["turn_status", { "status" => "completed", "variant_public_id" => "v-selected", "run_public_id" => "al-selected" }],
      ].each_with_index.map do |(type, payload), index|
        { "public_id" => "ev-#{index + 1}", "sequence" => index + 1, "cursor" => "c#{index + 1}", "type" => type,
          "resource" => { "type" => "conversation", "public_id" => "c-7" }, "occurred_at" => "2026-09-20T00:00:00Z",
          "payload" => payload.merge("turn_public_id" => "t-1") }
      end
    end
end
