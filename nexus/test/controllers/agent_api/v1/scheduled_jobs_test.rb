require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ScheduledJobsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @at = DatabaseClock.now + 1.hour
  end

  test "create is a hosted receipt and never queues work on the main conversation" do
    post jobs_path, headers: auth("first"), params: { scheduled_job: fields }, as: :json
    assert_response :created
    row = response.parsed_body.fetch("scheduled_job")
    assert_equal Nexus::Contract.pack.fetch("scheduled_jobs.json").fetch("projection").sort, row.keys.sort
    assert_equal "active", row.fetch("status")
    assert_equal @conversation.public_id, row.fetch("conversation_public_id")
    assert_equal @human.public_id, row.fetch("creating_user_public_id")
    assert_nil row["last_execution"]
    assert_equal 0, @conversation.conversation_inputs.count

    post jobs_path, headers: auth("first"), params: { scheduled_job: fields }, as: :json
    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal row.fetch("public_id"), response.parsed_body.dig("scheduled_job", "public_id")
    assert_equal 1, @conversation.scheduled_jobs.count

    post jobs_path, headers: auth("first"), params: { scheduled_job: fields.merge(prompt: "different") }, as: :json
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "read and optimistic edits preserve the execution identity and policy" do
    job = create_job
    patch "#{jobs_path}/#{job.public_id}", headers: auth, as: :json,
      params: { scheduled_job: { prompt: "new instructions", expected_lock_version: job.lock_version,
        creating_user_id: users(:owner).id, status: "canceled" } }
    assert_response :success
    assert_equal "new instructions", job.reload.prompt
    assert_equal @human, job.creating_user
    assert_equal "active", job.status
    assert_equal [], job.tool_names

    patch "#{jobs_path}/#{job.public_id}", headers: auth, as: :json,
      params: { scheduled_job: { prompt: "stale", expected_lock_version: 0 } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    get "#{jobs_path}/#{job.public_id}", headers: auth
    assert_response :success
    assert_equal "new instructions", response.parsed_body.dig("scheduled_job", "prompt")
  end

  test "pause resume and cancel are named idempotent commands" do
    job = create_job
    2.times do
      post "#{jobs_path}/#{job.public_id}/pause", headers: auth
      assert_response :success
      assert_equal "paused", response.parsed_body.dig("scheduled_job", "status")
      assert_nil response.parsed_body.dig("scheduled_job", "next_run_at")
    end
    post "#{jobs_path}/#{job.public_id}/resume", headers: auth
    assert_response :success
    assert_equal "active", response.parsed_body.dig("scheduled_job", "status")
    post "#{jobs_path}/#{job.public_id}/cancel", headers: auth
    assert_response :success
    assert_equal "canceled", response.parsed_body.dig("scheduled_job", "status")
    post "#{jobs_path}/#{job.public_id}/resume", headers: auth
    assert_response :unprocessable_entity
    assert_equal "scheduled_job_finished", response.parsed_body.dig("error", "code")
  end

  test "a scoped miss stays absent and read-only members cannot create or edit" do
    job = create_job
    other = create_conversation!
    get "#{conversation_path(other)}/scheduled_jobs/#{job.public_id}", headers: auth
    assert_response :not_found

    reader = users(:curator)
    @token = create_access_token_fixture(user: reader, name: "Reader")
    @conversation.update!(access_default: "read")
    get jobs_path, headers: auth
    assert_response :success
    assert_equal [job.public_id], response.parsed_body.fetch("scheduled_jobs").map { |row| row.fetch("public_id") }
    post jobs_path, headers: auth("denied"), params: { scheduled_job: fields }, as: :json
    assert_response :forbidden
    post "#{jobs_path}/#{job.public_id}/pause", headers: auth
    assert_response :forbidden
  end

  test "invalid rules and a malformed tool restriction have no durable effect" do
    assert_no_difference("ScheduledJob.count") do
      post jobs_path, headers: auth("bad-rule"), as: :json,
        params: { scheduled_job: fields.merge(rule: { kind: "daily", local_time: "25:00", time_zone: "Moon" }) }
      assert_response :unprocessable_entity
      post jobs_path, headers: auth("bad-tools"), as: :json,
        params: { scheduled_job: fields.merge(tool_names: "read_file") }
      assert_response :bad_request
    end
  end

  test "last execution follows the child's current visibility on both job reads and execution history" do
    job = create_job
    assert_equal :dispatched, ScheduledJobs::Dispatch.call(id: job.id, cutoff: @at)
    child = job.reload.last_execution_conversation
    @token = create_access_token_fixture(user: users(:curator), name: "Scheduled reader")
    get "#{jobs_path}/#{job.public_id}", headers: auth
    assert_response :success
    assert_equal child.public_id, response.parsed_body.dig("scheduled_job", "last_execution", "child_conversation_public_id")

    changed = Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
      conversation: child, acting_user: @human, default: "none", entries: []
    ))
    assert_predicate changed, :accepted?
    assert_execution_hidden(job)

    changed = Conversations::SetAccess.call(Conversations::SetAccess::Command.new(
      conversation: child, acting_user: @human, default: "full", entries: []
    ))
    assert_predicate changed, :accepted?
    get "#{jobs_path}/#{job.public_id}", headers: auth
    assert_equal child.public_id, response.parsed_body.dig("scheduled_job", "last_execution", "child_conversation_public_id")

    child.update!(tombstoned_at: Time.current)
    assert_execution_hidden(job)
  end

  test "list and executions use bounded opaque pagination with a durable run checkpoint" do
    jobs = 3.times.map { create_job }
    get jobs_path, headers: auth, params: { limit: 2 }
    assert_response :success
    first = response.parsed_body
    assert_equal 2, first.fetch("scheduled_jobs").length
    cursor = first.dig("pagination", "next_after")
    assert cursor
    get jobs_path, headers: auth, params: { limit: 2, after: cursor }
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("scheduled_jobs").length

    job = jobs.first
    assert_equal :dispatched, ScheduledJobs::Dispatch.call(id: job.id, cutoff: @at)
    get "#{jobs_path}/#{job.public_id}/executions", headers: auth
    assert_response :success
    execution = response.parsed_body.fetch("executions").sole
    assert_equal Nexus::Contract.pack.fetch("scheduled_jobs.json").fetch("execution_projection").sort, execution.keys.sort
    assert_equal "queued", execution.fetch("status")
    assert_equal job.reload.last_execution_conversation.public_id, execution.fetch("child_conversation_public_id")
    assert_nil execution["agent_loop_public_id"]
    checkpoint = response.parsed_body.dig("pagination", "last_cursor")
    assert checkpoint
    get "#{jobs_path}/#{job.public_id}/executions", headers: auth, params: { after: checkpoint }
    assert_response :success
    assert_empty response.parsed_body.fetch("executions")
    assert_equal checkpoint, response.parsed_body.dig("pagination", "last_cursor")
  end

  private

    def assert_execution_hidden(job)
      get "#{jobs_path}/#{job.public_id}", headers: auth
      assert_response :success
      assert_nil response.parsed_body.fetch("scheduled_job").fetch("last_execution")
      get jobs_path, headers: auth
      assert_response :success
      assert_nil response.parsed_body.fetch("scheduled_jobs").sole.fetch("last_execution")
      get "#{jobs_path}/#{job.public_id}/executions", headers: auth
      assert_response :success
      assert_empty response.parsed_body.fetch("executions")
    end

    def jobs_path = "#{conversation_path(@conversation)}/scheduled_jobs"

    def fields
      { name: "Check mail", prompt: "Check mail and report", model: { model: "dev/mock-text" },
        tool_names: [], rule: { kind: "once", run_at: @at.iso8601(6) } }
    end

    def create_job
      post jobs_path, headers: auth(SecureRandom.uuid), params: { scheduled_job: fields }, as: :json
      assert_response :created
      @conversation.scheduled_jobs.find_by!(public_id: response.parsed_body.dig("scheduled_job", "public_id"))
    end
end
