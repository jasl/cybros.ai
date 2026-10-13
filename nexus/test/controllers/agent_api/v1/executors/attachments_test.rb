require "test_helper"

class AgentAPI::V1::Executors::AttachmentsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @upload = upload
    @loop = seed(tool("held", "read_file", "timeout_ms" => 60_000))
    result = ContentBodies::Replace.call(owner: task, role: "input", seal: true,
      entries: [{ "role" => "user", "parts" => [{ "type" => "upload", "upload_public_id" => @upload.public_id }] }],
      uploads: [@upload])
    assert_predicate result, :accepted?
    assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @loop, acting_user: @human)), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    post agent_api_v1_executor_inbox_claim_path(run_public_id: @loop.public_id, task_key: "held"), headers: headers
    assert_response :success
    @claim = response.parsed_body.fetch("claim").fetch("claim_token")
  end

  test "the active claimant reads the bound descriptor and complete or ranged bytes without a signed URL" do
    get attachment_path, headers: headers(@claim)
    assert_response :success
    assert_equal @upload.public_id, response.parsed_body.dig("upload", "public_id")
    assert_equal "paper.pdf", response.parsed_body.dig("upload", "filename")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not_includes response.body, @claim

    get "#{attachment_path}/bytes", headers: headers(@claim)
    assert_response :success
    assert_equal "%PDF-attachment", response.body
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Location"]
    get "#{attachment_path}/bytes", headers: headers(@claim).merge("Range" => "bytes=0-3")
    assert_response :partial_content
    assert_equal "%PDF", response.body
  end

  test "a wrong token or missing proof cannot read attachment metadata" do
    get attachment_path, headers: headers("wrong-token")
    assert_response :conflict
    assert_equal "not_claimant", response.parsed_body.dig("error", "code")
    get attachment_path, headers: headers
    assert_response :bad_request
    assert_equal "parameter_missing", response.parsed_body.dig("error", "code")
  end

  test "another executor and a member bearer cannot reuse the claimant's proof" do
    replacement = connect_runner(manager: users(:owner), registration_identifier: "attachment-other-runner",
      assignment_scope: :account_wide)
    get attachment_path, headers: headers(@claim).merge("Authorization" => "Bearer #{replacement.executor_access_secret}")
    assert_response :conflict
    assert_equal "not_claimant", response.parsed_body.dig("error", "code")

    member = create_access_token_fixture(user: @human, name: "Attachment member")
    get "#{attachment_path}/bytes", headers: headers(@claim).merge("Authorization" => "Bearer #{member.secret}")
    assert_response :unauthorized
  end

  test "a staged upload and another loop's bound file remain absent" do
    unrelated = upload
    get attachment_path(unrelated), headers: headers(@claim)
    assert_response :not_found
    other = seed(tool("other", "read_file"))
    ContentBodies::Replace.call(owner: other.agent_run_tasks.sole, role: "input", seal: true,
      entries: [{ "text" => "other input" }], uploads: [unrelated])
    get "#{attachment_path(unrelated)}/bytes", headers: headers(@claim)
    assert_response :not_found
  end

  test "an elapsed or settled claim cannot read bytes" do
    task.update_columns(await_started_at: 2.minutes.ago)
    get "#{attachment_path}/bytes", headers: headers(@claim)
    assert_response :conflict
    assert_equal "claim_inactive", response.parsed_body.dig("error", "code")
    task.update_columns(await_started_at: Time.current, status: "completed")
    get attachment_path, headers: headers(@claim)
    assert_response :conflict
    assert_equal "claim_inactive", response.parsed_body.dig("error", "code")
  end

  test "pause preserves the existing claim and its input file capability" do
    assert_predicate AgentRuns::Pause.call(AgentRuns::Pause::Command.graceful(agent_run: @loop, acting_user: @human)), :accepted?
    get "#{attachment_path}/bytes", headers: headers(@claim)
    assert_response :success
    assert_equal "%PDF-attachment", response.body
  end

  test "a later claimant imports a committed PDF capture while staging and the settled claim grant nothing" do
    capture = @account.content_uploads.create!(creating_executor: suite_runner,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-captured"), filename: "capture.pdf",
        content_type: "application/pdf", identify: false))
    get attachment_path(capture), headers: headers(@claim)
    assert_response :not_found
    assert_predicate grow(@loop, tool("import", "read_file")), :applied?

    post agent_api_v1_executor_inbox_commit_path(run_public_id: @loop.public_id, task_key: "held"),
      headers: headers, as: :json, params: { claim_token: @claim, outcome: "completed",
        content: [{ type: "resource_link", uri: "nexus://uploads/#{capture.public_id}", name: "capture.pdf" }] }
    assert_response :success
    get attachment_path(capture), headers: headers(@claim)
    assert_response :conflict
    assert_equal "claim_inactive", response.parsed_body.dig("error", "code")

    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    post agent_api_v1_executor_inbox_claim_path(run_public_id: @loop.public_id, task_key: "import"), headers: headers
    assert_response :success
    token = response.parsed_body.fetch("claim").fetch("claim_token")
    path = "/agent_api/v1/executor/inbox/#{@loop.public_id}/import/attachments/#{capture.public_id}"
    get path, headers: headers(token)
    assert_response :success
    assert_equal capture.public_id, response.parsed_body.dig("upload", "public_id")
    get "#{path}/bytes", headers: headers(token).merge("Range" => "bytes=0-3")
    assert_response :partial_content
    assert_equal "%PDF", response.body
    get "#{path}/bytes", headers: headers(token)
    assert_response :success
    assert_equal "%PDF-captured", response.body
  end

  private

    def upload
      @account.content_uploads.create!(creating_user: @human,
        file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-attachment"), filename: "paper.pdf",
          content_type: "application/pdf", identify: false))
    end

    def task = @loop.agent_run_tasks.find_by!(node_key: "held")

    def headers(token = nil)
      { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}", "Claim-Token" => token }.compact
    end

    def attachment_path(upload = @upload)
      "/agent_api/v1/executor/inbox/#{@loop.public_id}/held/attachments/#{upload.public_id}"
    end
end
