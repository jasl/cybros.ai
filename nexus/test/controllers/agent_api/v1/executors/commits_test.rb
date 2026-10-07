require "test_helper"

# POST /agent_api/v1/executor/inbox/{loop}/{task_key}/commit — the executor plane's commit: the
# address proves the door, the token proves the claim, and ONE `Parks::Settle` decides — write-once,
# `idle` under the same token after the settle, `stale_claim` for a dead token, the deadline wins;
# payload refusals are 422 and leave the park standing.
class AgentAPI::V1::Executors::CommitsTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @member = create_access_token_fixture(user: @human, name: "Member")
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(agent_run, acting_user: @human)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: acting_user))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def runner_bearer = bearer(suite_runner_connection.executor_access_secret)

  def claim!(agent_run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def commit(agent_run, key, headers: runner_bearer, **body)
    post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id, task_key: key),
      headers: headers, as: :json, params: body
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def assert_refused(code, status: :conflict)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
  end

  test "a claimed row commits completed; the same commit again is idle; a dead token is stale_claim" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")

    commit(agent_run, "alpha", claim_token: "not-the-token", content: "x")
    assert_refused("stale_claim")

    commit(agent_run, "alpha", claim_token: token, content: "done", title: "read alpha")
    assert_response :success
    assert_equal "completed", response.parsed_body.dig("task", "status")
    assert_equal "alpha", response.parsed_body.dig("task", "key")
    assert_equal "completed", node(agent_run, "alpha").status
    assert_equal "read alpha", node(agent_run, "alpha").result_title

    commit(agent_run, "alpha", claim_token: token, content: "again")
    assert_response :success, "write-once: a second commit under the same token is idle, never a conflict"
    assert_equal "completed", response.parsed_body.dig("task", "status")
    assert_equal "done", node(agent_run, "alpha").output_preview
  end

  test "a failed outcome takes on_failure; is_error on a completed outcome is data" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")

    commit(agent_run, "alpha", claim_token: token, content: "boom", outcome: "completed", is_error: true)
    assert_response :success
    assert_equal "completed", node(agent_run, "alpha").status
    assert_equal true, node(agent_run, "alpha").output_summary["is_error"]
  end

  test "the JSON structured value distinguishes explicit null and false from an absent field" do
    [nil, false].each_with_index do |value, index|
      key = "value#{index}"
      agent_run = start!(seed(tool(key)))
      token = claim!(agent_run, key)

      commit(agent_run, key, claim_token: token, structured_content: value)

      assert_response :success
      assert_equal [{ "structured" => value }], node(agent_run, key).output_body.entry_payloads
      detail = AgentAPI::AgentRunPresenter.task_detail(node(agent_run, key))
      assert detail.key?(:structured_content)
      value.nil? ? assert_nil(detail.fetch(:structured_content)) : assert_equal(value, detail.fetch(:structured_content))
    end
    agent_run = start!(seed(tool("absent")))
    token = claim!(agent_run, "absent")
    commit(agent_run, "absent", claim_token: token)
    assert_response :success
    assert_nil node(agent_run, "absent").output_body
    refute AgentAPI::AgentRunPresenter.task_detail(node(agent_run, "absent")).key?(:structured_content)
  end

  test "the address proves the door: the other runner with the holder's token is not_addressed_here" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")
    second = connect_runner(manager: users(:owner), registration_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide)

    commit(agent_run, "alpha", headers: bearer(second.executor_access_secret), claim_token: token, content: "x")
    assert_refused("not_addressed_here")
    assert_equal "dispatched", node(agent_run, "alpha").status
  end

  test "the deadline wins: a late commit settles timed_out and the content is discarded" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")
    AgentRunTask.where(id: node(agent_run, "alpha").id).update_all(await_started_at: 2.hours.ago)

    commit(agent_run, "alpha", claim_token: token, content: "too late")
    assert_response :success
    assert_equal "timed_out", node(agent_run, "alpha").status
    assert_nil node(agent_run, "alpha").output_preview
  end

  test "payload refusals are 422 and leave the park standing" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")

    commit(agent_run, "alpha", claim_token: token, content: "x", outcome: "maybe")
    assert_refused("invalid_outcome", status: :unprocessable_entity)
    commit(agent_run, "alpha", claim_token: token,
      content: "x" * (Nexus::SizeBounds.fetch(:snapshot_bound) + 1))
    assert_refused("result_too_large", status: :unprocessable_entity)
    assert_equal "dispatched", node(agent_run, "alpha").status
  end

  test "the dedication fence at commit: the principal losing write standing after the claim is not_authorized" do
    agent_run = start!(seed(tool("alpha"), creating_user: users(:agent)), acting_user: users(:agent))
    token = claim!(agent_run, "alpha")
    Workspace.where(id: @workspace.id).update_all(agent_identifier: "someone-else")

    commit(agent_run, "alpha", claim_token: token, content: "x")
    assert_refused("not_authorized")
    assert_equal "dispatched", node(agent_run, "alpha").status
  end

  # THE ASK'S TWO DOORS: the agent application commits on its transport bearer with no claim_token —
  # the address is the door; the same commit again is idle; the person's resolution door afterwards
  # answers 200 idle over the same Settle; a member bearer here is 401.
  test "an ask commits on its addressee's transport bearer with no claim_token; the second door is idle" do
    agent_run = seed(ask("q", "prompt" => "which database?"), creating_user: users(:agent))
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: users(:agent)))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    address = task_executors(:address)
    AgentRunTask.where(id: agent_run.agent_run_tasks.sole.id).update_all(
      resolution_token: nil, status: "awaiting_input",
      addressed_executor_id: address.id, addressed_role: "agent_application"
    )
    transport = create_bound_credential(executor: address, name: "Transport")

    commit(agent_run, "q", headers: bearer(@member.secret), content: "Postgres")
    assert_response :unauthorized

    commit(agent_run, "q", headers: bearer(transport.secret), content: "Postgres")
    assert_response :success
    assert_equal "completed", response.parsed_body.dig("task", "status")
    assert_equal "completed", node(agent_run, "q").status
    assert_equal "Postgres", node(agent_run, "q").output_preview

    commit(agent_run, "q", headers: bearer(transport.secret), content: "again")
    assert_response :success, "write-once: the second commit is idle, never a conflict"
    assert_equal "Postgres", node(agent_run, "q").output_preview

    post "/agent_api/v1/workspaces/#{@workspace.public_id}/runs/#{agent_run.public_id}/tasks/q/resolution",
      headers: bearer(@member.secret), as: :json, params: { content: "MySQL" }
    assert_response :success, "the person's door over the same Settle answers idle with the task as it stands"
    assert_equal "completed", response.parsed_body.dig("task", "status")
    assert_equal "Postgres", node(agent_run, "q").output_preview
  end

  test "a missing key is 404, a member bearer is 401" do
    agent_run = start!(seed(tool("alpha")))
    commit(agent_run, "nope", claim_token: "x", content: "x")
    assert_response :not_found
    commit(agent_run, "alpha", headers: bearer(@member.secret), claim_token: "x", content: "x")
    assert_response :unauthorized
  end
end

# THE `resource_link` BLOCK: a commit's `content` may name a CAPTURE this executor staged on its own
# plane — MCP's own `ResourceLink`, `nexus://uploads/<id>` the one scheme, `name` required, the
# optional fields typed and stored verbatim. The linked rows are resolved as THIS executor's own
# between the loop lock and the node lock and BOUND by the body; an id that is not its capture is
# `422 unknown_result_upload` with the park standing — the input door's `unknown_input_upload` twin
# — and the same token then commits text alone.
class AgentAPI::V1::Executors::CommitLinksTest < ActionDispatch::IntegrationTest
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
  end

  def tool(key, **over) = super(key, "read_file", "input" => { "path" => key }, **over)

  def start!(agent_run)
    AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: agent_run, acting_user: @human))
    AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
    agent_run
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def claim!(agent_run, key)
    result = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: agent_run, task_key: key, executor: suite_runner
    ))
    assert_predicate result, :accepted?, result.outcome.inspect
    result.value.claim_token
  end

  def commit(agent_run, key, **body)
    post agent_api_v1_executor_inbox_commit_path(run_public_id: agent_run.public_id, task_key: key),
      headers: bearer(suite_runner_connection.executor_access_secret), as: :json, params: body
  end

  def node(agent_run, key) = agent_run.agent_run_tasks.find_by!(node_key: key)

  def staged(**creator)
    @account.content_uploads.create!(
      **creator,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PNG), filename: "shot.png",
        content_type: "image/png")
    )
  end

  def link(upload_or_id, **fields)
    id = upload_or_id.respond_to?(:public_id) ? upload_or_id.public_id : upload_or_id
    { type: "resource_link", uri: "nexus://uploads/#{id}", name: "shot.png" }.merge(fields)
  end

  def assert_refused(code, agent_run, key)
    assert_response :unprocessable_entity
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_equal "dispatched", node(agent_run, key).status, "the park stands"
  end

  test "a link names this executor's own capture: bound by the body, rendered as its block, the output the text alone" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")
    capture = staged(creating_executor: suite_runner)

    commit(agent_run, "alpha", claim_token: token,
      content: [{ type: "text", text: "Saved a screenshot" },
                link(capture, mimeType: "image/png", size: PNG.bytesize, title: "the sign-in page",
                     description: "after submit")],
      title: "screenshot", metadata: { checkpoint: "c1" })
    assert_response :success
    assert_equal "completed", node(agent_run, "alpha").status

    body = node(agent_run, "alpha").content_bodies.find_by!(role: "output")
    assert_equal [capture.id], body.content_uploads.map(&:id), "the body binds the capture"
    assert_equal "Saved a screenshot", body.effective_text, "the model reads the text alone"
    detail = AgentAPI::AgentRunPresenter.task_detail(node(agent_run, "alpha"))
    assert_equal "Saved a screenshot", detail.fetch(:output)
    assert_equal [
      { type: "text", text: "Saved a screenshot" },
      { type: "resource_link", uri: "nexus://uploads/#{capture.public_id}", name: "shot.png",
        mimeType: "image/png", title: "the sign-in page", description: "after submit",
        size: PNG.bytesize },
    ], detail.fetch(:content), "the block re-rendered from the stored entry, every typed field verbatim"
    assert_equal "screenshot", detail.fetch(:title)
    assert_equal({ "checkpoint" => "c1" }, detail.fetch(:metadata))
    assert_not ContentUpload.unbound.exists?(id: capture.id)
  end

  test "a link that is not this executor's capture is unknown_result_upload with the park standing, then text commits" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")
    second = connect_runner(manager: users(:owner), registration_identifier: "test-runner-2",
      display_name: "Second runner", assignment_scope: :account_wide)

    [staged(creating_user: @human), staged(creating_executor: second.executor_access_token.task_executor),
     SecureRandom.uuid_v7].each do |foreign|
      commit(agent_run, "alpha", claim_token: token, content: [{ type: "text", text: "x" }, link(foreign)])
      assert_refused("unknown_result_upload", agent_run, "alpha")
    end
    assert_nil node(agent_run, "alpha").content_bodies.find_by(role: "output"), "nothing was written"

    commit(agent_run, "alpha", claim_token: token, content: "text alone")
    assert_response :success
    assert_equal "completed", node(agent_run, "alpha").status
    assert_equal "text alone", node(agent_run, "alpha").output_preview
  end

  test "another scheme, a missing name or a mistyped field is invalid_content" do
    agent_run = start!(seed(tool("alpha")))
    token = claim!(agent_run, "alpha")
    capture = staged(creating_executor: suite_runner)

    commit(agent_run, "alpha", claim_token: token,
      content: [{ type: "resource_link", uri: "https://example.test/shot.png", name: "shot.png" }])
    assert_refused("invalid_content", agent_run, "alpha")
    commit(agent_run, "alpha", claim_token: token,
      content: [{ type: "resource_link", uri: "nexus://uploads/not-a-uuid", name: "shot.png" }])
    assert_refused("invalid_content", agent_run, "alpha")
    commit(agent_run, "alpha", claim_token: token, content: [link(capture).except(:name)])
    assert_refused("invalid_content", agent_run, "alpha")
    commit(agent_run, "alpha", claim_token: token, content: [link(capture, name: "")])
    assert_refused("invalid_content", agent_run, "alpha")
    commit(agent_run, "alpha", claim_token: token, content: [link(capture, size: "big")])
    assert_refused("invalid_content", agent_run, "alpha")
    commit(agent_run, "alpha", claim_token: token, content: [link(capture, mimeType: 7)])
    assert_refused("invalid_content", agent_run, "alpha")
    commit(agent_run, "alpha", claim_token: token, content: [{ type: "image", data: "…" }])
    assert_refused("unsupported_content_kind", agent_run, "alpha")
  end
end
