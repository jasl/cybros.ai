require "test_helper"

class CoreControlsTest < Minitest::Test
  include RhoTest::CliHarness

  def body_of(request) = JSON.parse(request.partition("\r\n\r\n").last)

  # `stop` posts force as told and the branch key when one is named, and
  # answers the `stopped` row; `compact` and `open_side` answer theirs.
  def test_stop_compact_and_open_side_answer_their_documents
    seen = []
    stopped = { "host_type" => "task", "public_id" => "r3t1", "status" => "canceled", "run_public_id" => "al-9" }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /stop" => [[200, { "stopped" => stopped }]],
      "POST /compact" => [[200, { "compacted" => { "public_id" => "c-1", "host_type" => "conversation" } }],
                          [409, { "error" => { "code" => "busy", "message" => "the reply is compacting already" } }]],
      "POST /side" => [[201, { "side" => { "public_id" => "c-side" }, "parent" => { "public_id" => "c-1" }, "reused" => false }]]))

    assert_equal stopped, core.stop("c-1", "r3t1", force: false)
    assert_equal({ "public_id" => "c-1", "force" => false, "task_key" => "r3t1", "host_type" => "conversation" }, body_of(seen.grep(%r{\APOST /stop }).last))
    core.stop("c-1")
    assert_equal({ "public_id" => "c-1", "force" => true, "host_type" => "conversation" }, body_of(seen.grep(%r{\APOST /stop }).last), "no key, no branch; force by default")

    assert_equal({ "public_id" => "c-1", "host_type" => "conversation" }, core.compact("c-1"))
    assert_equal({ "public_id" => "c-1" }, body_of(seen.grep(%r{\APOST /compact }).last))
    error = assert_raises(Rho::Error) { core.compact("c-1", "r2") }
    assert_equal "the reply is compacting already", error.message

    side = core.open_side(parent: "c-1", tools: "write", text: "why?")
    assert_equal "c-side", side.dig("side", "public_id")
    assert_equal({ "tools" => "write", "parent_public_id" => "c-1", "text" => "why?" }, body_of(seen.grep(%r{\APOST /side }).last))
  end

  def test_exact_run_stop_names_its_type_and_preserves_the_task_and_force
    seen = []
    stopped = { "host_type" => "task", "public_id" => "r1", "run_public_id" => "al-old", "status" => "canceled" }
    announce(endpoint: recording_endpoint(seen, 200, { "stopped" => stopped }))

    assert_equal stopped, core.stop("al-old", "r1", force: false, host_type: "run")
    assert_equal({ "public_id" => "al-old", "task_key" => "r1", "force" => false, "host_type" => "run" },
      JSON.parse(seen.grep(%r{\APOST /stop }).last.partition("\r\n\r\n").last))
  end

  def test_pending_controls_forward_the_original_workspace_without_changing_ordinary_calls
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /runs/approve" => [[200, { "task" => {} }]],
      "POST /runs/deny" => [[200, { "task" => {} }]],
      "POST /answer" => [[200, { "answered" => { "door" => "executor" } }]]))

    core.approve("child-run", "tool", workspace_public_id: "original")
    core.deny("child-run", "tool", reason: "no", workspace_public_id: "original")
    core.answer("child-run", "ask", "yes", workspace_public_id: "original")
    posts = seen.grep(/\APOST /)
    assert_equal ["original"] * 3, posts.map { |request| body_of(request).fetch("workspace_public_id") }
    core.approve("child-run", "tool")
    core.deny("child-run", "tool")
    core.answer("child-run", "ask", "yes")
    assert seen.grep(/\APOST /).last(3).none? { |request| body_of(request).key?("workspace_public_id") }
  end

  def test_activation_names_the_exact_turn_and_candidate
    seen = []
    variant = { "public_id" => "v-old", "active" => true, "run_public_id" => "al-old" }
    announce(endpoint: recording_endpoint(seen, 200, { "variant" => variant }))

    assert_equal variant, core.activate_variant("c-1", "t-1", "v-old")
    request = seen.grep(%r{\APOST /conversations/activate }).last
    refute_nil request
    assert_equal({ "public_id" => "c-1", "turn" => "t-1", "variant" => "v-old" },
      JSON.parse(request.partition("\r\n\r\n").last))
    assert_empty @out.string
  end

  def test_activation_keeps_the_kernel_refusal
    announce(endpoint: recording_endpoint([], 409,
      { "error" => { "code" => "variant_not_active", "message" => "candidate is still running" } }))

    error = assert_raises(Rho::Error) { core.activate_variant("c-1", "t-1", "v-2") }
    assert_includes error.message, "candidate is still running"
  end
end
