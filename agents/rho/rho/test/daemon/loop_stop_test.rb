require "support/daemon_loop_helpers"

class DaemonLoopStopTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_explicit_loop_stop_never_resolves_to_its_conversation_before_or_after_a_new_turn
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", loop: "al-old")

    ["al-old", "al-new"].each do |current_loop|
      store.remember(conversation_host("c-1"), workspace: "ws-1", loop: current_loop)
      response = request(daemon, :post, "/stop", token: bearer(daemon),
        body: { public_id: "al-old", host_type: "agent_loop", force: false })

      assert_equal "200", response.code, response.body
      stopped = JSON.parse(response.body).fetch("stopped")
      assert_equal "agent_loop", stopped.fetch("host_type")
      assert_equal "al-old", stopped.fetch("public_id")
    end
    paths = api.requests.map(&:first)
    assert_equal 2, paths.count { |path| path.end_with?("/agent_loops/al-old/stop") }
    refute paths.any? { |path| path.end_with?("/cancellation", "/agent_loops/al-new/stop") }
    assert_equal "al-new", store.find("c-1").loop
  end

  def test_exact_loop_task_cancel_needs_no_follow_and_leaves_the_new_loop_alone
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", loop: "al-new")
    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "al-old", host_type: "agent_loop", task_key: "r3t1" })

    assert_equal "200", response.code, response.body
    stopped = JSON.parse(response.body).fetch("stopped")
    assert_equal "task", stopped.fetch("host_type")
    assert_equal "al-old", stopped.fetch("loop")
    paths = api.requests.map(&:first)
    assert paths.any? { |path| path.end_with?("/agent_loops/al-old/tasks/r3t1/cancel") }
    refute paths.any? { |path| path.end_with?("/cancellation", "/agent_loops/al-new/tasks/r3t1/cancel") }
  end

  def test_an_unknown_untyped_id_is_not_guessed_to_be_a_conversation
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)

    ["al-old", "c-unknown"].each do |public_id|
      response = request(daemon, :post, "/stop", token: bearer(daemon), body: { public_id: public_id })
      assert_equal "404", response.code, response.body
      assert_equal "host_not_followed", JSON.parse(response.body).dig("error", "code")
    end
    refute api.requests.any? { |path, _| path.end_with?("/stop", "/cancellation") }
  end

  def test_explicit_conversation_stop_uses_cancellation_without_enumerating_loops
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "c-child", host_type: "conversation" })

    assert_equal "200", response.code, response.body
    assert_equal({ "host_type" => "conversation", "public_id" => "c-child", "status" => "canceling", "followed" => false },
      JSON.parse(response.body).fetch("stopped"))
    paths = api.requests.map(&:first)
    assert paths.any? { |path| path.end_with?("/conversations/c-child/cancellation") }
    refute paths.any? { |path| path.include?("/agent_loops") }

    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "c-child", host_type: "conversation", task_key: "r1" })
    assert_equal "404", response.code, "a conversation with no known current loop cannot name its task"
  end

  def test_invalid_host_type_refuses_before_a_stop
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "al-old", host_type: "loop" })

    assert_equal "400", response.code, response.body
    assert_equal "host_type must be agent_loop or conversation", JSON.parse(response.body).dig("error", "message")
    refute api.requests.any? { |path, _| path.end_with?("/stop", "/cancellation") }
  end
end
