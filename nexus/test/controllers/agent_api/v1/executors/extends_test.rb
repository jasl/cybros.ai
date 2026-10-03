require "test_helper"

# POST /agent_api/v1/executor/inbox/{loop}/{task_key}/extend — the claimant's
# extension on the executor plane (review 2026-09-08, change 8), beside the
# claim and the commit it sits between: the row's current claimant moves
# the one clock by a bounded amount and reads back the same `{task, claim}`
# a grant answers, deadline moved; every refusal is a 409 under one code, a
# malformed body a 422, a loop outside the executor's account absence.
class AgentAPI::V1::Executors::ExtendsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @member = create_access_token_fixture(user: @human, name: "Member")
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(agent_loop, acting_user: @human)
    AgentLoops::Start.call(AgentLoops::Start::Command.new(agent_loop: agent_loop, acting_user: acting_user))
    AgentLoops::ScheduleReady.call(agent_loop_id: agent_loop.id)
    agent_loop
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def runner_bearer = bearer(suite_runner_connection.executor_access_secret)

  def claim!(agent_loop, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_loop: agent_loop, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def extend(agent_loop, key, headers: runner_bearer, **body)
    post agent_api_v1_executor_inbox_extend_path(agent_loop_public_id: agent_loop.public_id, task_key: key),
      headers: headers, as: :json, params: body
  end

  def node(agent_loop, key) = agent_loop.agent_loop_nodes.find_by!(node_key: key)

  def assert_refused(code, status: :conflict)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
  end

  test "the claimant's extension answers the row and its claim with the deadline moved" do
    agent_loop = start!(seed(tool("alpha", "timeout_ms" => 60_000)))
    token = claim!(agent_loop, "alpha")
    before = node(agent_loop, "alpha").deadline_at

    extend(agent_loop, "alpha", claim_token: token, timeout_ms: 15.minutes.in_milliseconds)

    assert_response :success
    task = response.parsed_body.fetch("task")
    assert_equal "alpha", task.fetch("task_key")
    assert_equal true, task.fetch("claimed")
    claim = response.parsed_body.fetch("claim")
    assert_equal token, claim.fetch("claim_token"), "nothing rotates"
    deadline = Time.iso8601(claim.fetch("deadline_at"))
    assert_operator deadline, :>, before
    assert_in_delta 15.minutes.from_now.to_f, deadline.to_f, 5
    assert_equal deadline.to_i, node(agent_loop, "alpha").reload.deadline_at.to_i
    assert_equal deadline.iso8601, task.fetch("deadline_at")
    assert_equal 60_000, task.fetch("timeout_ms"), "the extension moves the clock, never the budget"
  end

  { "at" => 0, "after" => 1.second }.each do |boundary, offset|
    test "an extension #{boundary} the deadline cannot revive a claim before the sweep runs" do
      agent_loop = start!(seed(tool("alpha", "timeout_ms" => 60_000)))
      token = claim!(agent_loop, "alpha")
      parked = node(agent_loop, "alpha")
      travel_to parked.deadline_at + offset, with_usec: true
      assert_equal "dispatched", parked.status

      assert_no_changes -> { parked.reload.attributes } do
        assert_no_difference -> { agent_loop.conversation_event_items.count } do
          extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000)

          assert_refused("not_extendable")
        end
      end
    end
  end

  test "pause refuses extensions and graceful cancellation preserves the unexpired claim" do
    agent_loop = start!(seed(tool("alpha", "timeout_ms" => 60_000)))
    token = claim!(agent_loop, "alpha")
    path = "/agent_api/v1/workspaces/#{@workspace.public_id}/agent_loops/#{agent_loop.public_id}"

    post "#{path}/pause", headers: bearer(@member.secret), as: :json
    assert_response :success
    travel_to node(agent_loop, "alpha").deadline_at + 1.second, with_usec: true
    extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000)
    assert_refused("not_extendable")

    post "#{path}/stop", headers: bearer(@member.secret), as: :json, params: { force: false }
    assert_response :success
    assert_equal "canceling", agent_loop.reload.status
    assert_operator node(agent_loop, "alpha").deadline_at, :>, Time.current

    extend(agent_loop, "alpha", claim_token: token, timeout_ms: 60_000)
    assert_response :success
    assert_equal token, response.parsed_body.dig("claim", "claim_token")
    assert_in_delta 60.seconds.from_now.to_f, node(agent_loop, "alpha").deadline_at.to_f, 0.001
  end

  test "the three refusals are conflicts, and a malformed extension is unprocessable" do
    agent_loop = start!(seed(tool("alpha")))

    extend(agent_loop, "alpha", claim_token: "x", timeout_ms: 60_000)
    assert_refused("not_extendable")

    token = claim!(agent_loop, "alpha")
    extend(agent_loop, "alpha", claim_token: "wrong", timeout_ms: 60_000)
    assert_refused("not_claimant")

    extend(agent_loop, "alpha", claim_token: token, timeout_ms: 2.hours.in_milliseconds)
    assert_refused("extension_too_long")

    extend(agent_loop, "alpha", claim_token: token, timeout_ms: 0)
    assert_refused("invalid_timeout_ms", status: :unprocessable_entity)
    extend(agent_loop, "alpha", claim_token: token, timeout_ms: "soon")
    assert_refused("invalid_timeout_ms", status: :unprocessable_entity)
    extend(agent_loop, "alpha", claim_token: token)
    assert_refused("invalid_timeout_ms", status: :unprocessable_entity)
  end

  test "a member bearer never reaches the executor plane, and an unknown row is absence" do
    agent_loop = start!(seed(tool("alpha")))
    token = claim!(agent_loop, "alpha")

    extend(agent_loop, "alpha", headers: bearer(@member.secret), claim_token: token, timeout_ms: 60_000)
    assert_response :unauthorized

    extend(agent_loop, "nope", claim_token: token, timeout_ms: 60_000)
    assert_response :not_found
  end
end
