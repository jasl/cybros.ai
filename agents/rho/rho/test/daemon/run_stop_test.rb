require "support/daemon_run_helpers"

class DaemonRunStopTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def test_explicit_run_stop_never_resolves_to_its_conversation_before_or_after_a_new_turn
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-old")

    ["al-old", "al-new"].each do |current_run|
      store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: current_run)
      response = request(daemon, :post, "/stop", token: bearer(daemon),
        body: { public_id: "al-old", host_type: "run", force: false })

      assert_equal "200", response.code, response.body
      stopped = JSON.parse(response.body).fetch("stopped")
      assert_equal "run", stopped.fetch("host_type")
      assert_equal "al-old", stopped.fetch("public_id")
    end
    paths = api.requests.map(&:first)
    assert_equal 2, paths.count { |path| path.end_with?("/runs/al-old/stop") }
    refute paths.any? { |path| path.end_with?("/cancellation", "/runs/al-new/stop") }
    assert_equal "al-new", store.find("c-1").run_public_id
  end

  def test_exact_run_task_cancel_needs_no_follow_and_leaves_the_new_run_alone
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-new")
    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "al-old", host_type: "run", task_key: "r3t1" })

    assert_equal "200", response.code, response.body
    stopped = JSON.parse(response.body).fetch("stopped")
    assert_equal "task", stopped.fetch("host_type")
    assert_equal "al-old", stopped.fetch("run_public_id")
    paths = api.requests.map(&:first)
    assert paths.any? { |path| path.end_with?("/runs/al-old/tasks/r3t1/cancel") }
    refute paths.any? { |path| path.end_with?("/cancellation", "/runs/al-new/tasks/r3t1/cancel") }
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

  def test_explicit_conversation_stop_uses_cancellation_without_enumerating_runs
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "c-child", host_type: "conversation" })

    assert_equal "200", response.code, response.body
    assert_equal({ "host_type" => "conversation", "public_id" => "c-child", "status" => "canceling", "followed" => false },
      JSON.parse(response.body).fetch("stopped"))
    paths = api.requests.map(&:first)
    assert paths.any? { |path| path.end_with?("/conversations/c-child/cancellation") }
    refute paths.any? { |path| path.include?("/runs") }

    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "c-child", host_type: "conversation", task_key: "r1" })
    assert_equal "404", response.code, "a conversation with no known current run cannot name its task"
  end

  def test_invalid_host_type_refuses_before_a_stop
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :post, "/stop", token: bearer(daemon),
      body: { public_id: "al-old", host_type: "run_public_id" })

    assert_equal "400", response.code, response.body
    assert_equal "host_type must be run or conversation", JSON.parse(response.body).dig("error", "message")
    refute api.requests.any? { |path, _| path.end_with?("/stop", "/cancellation") }
  end
end
