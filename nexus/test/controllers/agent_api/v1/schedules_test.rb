require "test_helper"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::SchedulesTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper

  setup do
    @agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @at = DatabaseClock.now + 1.hour
  end

  test "create is a hosted receipt and never queues work on the main conversation" do
    post jobs_path, headers: auth("first"), params: { schedule: fields }, as: :json
    assert_response :created
    row = response.parsed_body.fetch("schedule")
    assert_equal Nexus::Contract.pack.fetch("schedules.json").fetch("projection").sort, row.keys.sort
    assert_equal "active", row.fetch("status")
    assert_equal @conversation.public_id, row.fetch("conversation_public_id")
    assert_equal @human.public_id, row.fetch("creating_user_public_id")
    assert_nil row["last_execution"]
    assert_equal 0, @conversation.conversation_inputs.count

    post jobs_path, headers: auth("first"), params: { schedule: fields }, as: :json
    assert_response :created
    assert_equal "true", response.headers["Idempotency-Replayed"]
    assert_equal row.fetch("public_id"), response.parsed_body.dig("schedule", "public_id")
    assert_equal 1, @conversation.schedules.count

    post jobs_path, headers: auth("first"), params: { schedule: fields.merge(prompt: "different") }, as: :json
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "read and optimistic edits preserve the execution identity and policy" do
    job = create_job
    patch "#{jobs_path}/#{job.public_id}", headers: auth, as: :json,
      params: { schedule: { prompt: "new instructions", expected_lock_version: job.lock_version,
        creating_user_id: users(:owner).id, status: "canceled" } }
    assert_response :success
    assert_equal "new instructions", job.reload.prompt
    assert_equal @human, job.creating_user
    assert_equal "active", job.status
    assert_equal [], job.tool_names

    patch "#{jobs_path}/#{job.public_id}", headers: auth, as: :json,
      params: { schedule: { prompt: "stale", expected_lock_version: 0 } }
    assert_response :conflict
    assert_equal "stale_object", response.parsed_body.dig("error", "code")

    get "#{jobs_path}/#{job.public_id}", headers: auth
    assert_response :success
    assert_equal "new instructions", response.parsed_body.dig("schedule", "prompt")
  end

  test "a declared child schedule captures its model intent and list while explicit equal selection pins the route" do
    declaration = ExecutionDeclaration.capture(@agent, default_model: "dev/mock-text", kernel_tools: [],
      fallback_models: ["dev/mock-unmetered"])
    intent = ModelSelectionIntent.new(source: "inherited", model: "dev/mock-text", constraint: "provider",
      alternatives: ["dev/mock-priced"])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      execution_declaration: declaration, model_selection: intent, fallback_models: ["dev/mock-unmetered"])
    @agent.update!(default_model: "dev/mock-priced", fallback_models: [])

    post jobs_path, headers: auth("captured"), params: { schedule: fields.except(:model) }, as: :json
    assert_response :created
    job = @conversation.schedules.find_by!(public_id: response.parsed_body.dig("schedule", "public_id"))
    assert_equal intent.as_json, response.parsed_body.dig("schedule", "model_selection")
    assert_equal ["dev/mock-unmetered"], response.parsed_body.dig("schedule", "fallback_models")
    assert_equal ["dev", "mock-text"], [job.provider_id, job.model_ref]
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: @at)
    child = job.reload.last_execution_conversation
    assert_equal intent, child.conversation_inputs.sole.model_selection
    assert_equal ["dev/mock-unmetered"], child.conversation_inputs.sole.fallback_models

    explicit = create_job
    assert_equal "explicit", explicit.model_selection.source
    assert_equal "route", explicit.model_selection.constraint
    patch "#{jobs_path}/#{explicit.public_id}", headers: auth, as: :json,
      params: { schedule: { expected_lock_version: explicit.lock_version, model: { reasoning_enabled: false } } }
    assert_response :success
    assert_equal "route", explicit.reload.model_selection.constraint
    patch "#{jobs_path}/#{explicit.public_id}", headers: auth, as: :json,
      params: { schedule: { expected_lock_version: explicit.lock_version, model_selection: intent.as_json,
        fallback_models: [] } }
    assert_response :success
    assert_equal intent, explicit.reload.model_selection
    assert_equal [], explicit.fallback_models
    patch "#{jobs_path}/#{explicit.public_id}", headers: auth, as: :json,
      params: { schedule: { expected_lock_version: explicit.lock_version, fallback_models: nil } }
    assert_response :success
    assert_equal ["dev/mock-unmetered"], explicit.reload.fallback_models
  end

  test "a differently addressed schedule uses that answerer's declaration and clears no unrelated capture" do
    declaration = ExecutionDeclaration.capture(@agent, default_model: "dev/mock-text",
      system_prompt: { "content" => "Original role only." })
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      execution_declaration: declaration, model_selection: ModelSelectionIntent.inherited("dev/mock-text"), fallback_models: [])
    other = User.create!(account: @account, kind: "agent", display_name: "Other", handle: "scheduled-other",
      steward: @human, agent_identifier: "scheduled-other")
    other.update!(default_model: "dev/mock-unmetered", fallback_models: ["dev/mock-priced"])
    post jobs_path, headers: auth("other-answerer"), as: :json,
      params: { schedule: fields.except(:model).merge(answering_user_public_id: other.public_id) }
    assert_response :created
    job = @conversation.schedules.find_by!(public_id: response.parsed_body.dig("schedule", "public_id"))
    assert_equal ["dev", "mock-unmetered"], [job.provider_id, job.model_ref]
    assert_equal ["dev/mock-priced"], job.fallback_models
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: @at)
    child = job.reload.last_execution_conversation
    assert_equal other, child.answering_user
    assert_nil child.execution_declaration
    assert_nil child.conversation_inputs.sole.execution_declaration
    assert_equal "dev/mock-unmetered", child.conversation_inputs.sole.model_selection.model
  end

  test "a control-only schedule creation preserves the captured model and the other reasoning control" do
    intent = ModelSelectionIntent.new(source: "inherited", model: "dev/mock-unmetered", constraint: "provider",
      alternatives: ["dev/mock-priced"])
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      execution_declaration: ExecutionDeclaration.capture(@agent, default_model: "dev/mock-unmetered"),
      model_selection: intent, fallback_models: ["dev/mock-windowless"])
    turn = ConversationTurn.create!(conversation: @conversation, position: 0, kind: "direct_reply",
      role: "assistant", status: "completed", speaker: Speakers::Resolve.member(account: @account, user: @human),
      control_owner_user: @human, answering_user: @agent)
    variant = turn.conversation_turn_variants.create!(position: 0, status: "completed", source: "fork",
      provider_id: "dev", model_ref: "mock-unmetered", reasoning_enabled: false, model_selection: intent)
    turn.update!(active_variant: variant)

    post jobs_path, headers: auth("control-only"), as: :json,
      params: { schedule: fields.merge(model: { reasoning_effort: "high" }) }
    assert_response :created
    row = response.parsed_body.fetch("schedule")
    assert_equal "dev/mock-unmetered", row.dig("model", "model")
    assert_equal "high", row.dig("model", "reasoning_effort")
    assert_equal false, row.dig("model", "reasoning_enabled")
    assert_equal intent.as_json, row.fetch("model_selection")
    assert_equal ["dev/mock-windowless"], row.fetch("fallback_models")
  end

  test "an ordinary schedule can capture the configured answerer model when the model is omitted" do
    @agent.update!(default_model: "dev/mock-text", fallback_models: ["dev/mock-unmetered"])
    post jobs_path, headers: auth("default-model"), params: { schedule: fields.except(:model) }, as: :json
    assert_response :created
    assert_equal "dev/mock-text", response.parsed_body.dig("schedule", "model", "model")
    assert_equal "default", response.parsed_body.dig("schedule", "model_selection", "source")
    assert_equal ["dev/mock-unmetered"], response.parsed_body.dig("schedule", "fallback_models")
  end

  test "pause resume and cancel are named idempotent commands" do
    job = create_job
    2.times do
      post "#{jobs_path}/#{job.public_id}/pause", headers: auth
      assert_response :success
      assert_equal "paused", response.parsed_body.dig("schedule", "status")
      assert_nil response.parsed_body.dig("schedule", "next_run_at")
    end
    post "#{jobs_path}/#{job.public_id}/resume", headers: auth
    assert_response :success
    assert_equal "active", response.parsed_body.dig("schedule", "status")
    post "#{jobs_path}/#{job.public_id}/cancel", headers: auth
    assert_response :success
    assert_equal "canceled", response.parsed_body.dig("schedule", "status")
    post "#{jobs_path}/#{job.public_id}/resume", headers: auth
    assert_response :unprocessable_entity
    assert_equal "schedule_finished", response.parsed_body.dig("error", "code")
  end

  test "the workspace index lists every readable conversation's jobs and conceals the rest" do
    job = create_job
    other = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent, title: "Other")
    post "#{conversation_path(other)}/schedules", headers: auth("other"), params: { schedule: fields }, as: :json
    assert_response :created
    foreign = response.parsed_body.dig("schedule", "public_id")
    hidden = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent, title: "Hidden")
    post "#{conversation_path(hidden)}/schedules", headers: auth("hidden"), params: { schedule: fields }, as: :json
    assert_response :created
    concealed = response.parsed_body.dig("schedule", "public_id")
    @conversation.update!(title: "Mail")

    get workspace_jobs_path, headers: auth
    assert_response :success
    rows = response.parsed_body.fetch("schedules")
    assert_equal [job.public_id, foreign, concealed].sort, rows.map { |row| row.fetch("public_id") }.sort
    assert_equal Nexus::Contract.pack.fetch("schedules.json").fetch("projection").sort, rows.first.keys.sort
    assert_equal "Mail", rows.find { |row| row.fetch("public_id") == job.public_id }.fetch("conversation_title")

    get workspace_jobs_path, headers: auth, params: { limit: 2 }
    assert_response :success
    assert_equal 2, response.parsed_body.fetch("schedules").length
    cursor = response.parsed_body.dig("pagination", "next_after")
    get workspace_jobs_path, headers: auth, params: { limit: 2, after: cursor }
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("schedules").length
    assert_nil response.parsed_body.dig("pagination", "next_after")

    # Another member reads only through conversations it can read: a level
    # of `none` conceals that conversation's jobs.
    @token = create_access_token_fixture(user: users(:curator), name: "Other reader")
    hidden.update!(access_default: "none")
    @conversation.update!(access_default: "none")
    get workspace_jobs_path, headers: auth
    assert_response :success
    assert_equal [foreign], response.parsed_body.fetch("schedules").map { |row| row.fetch("public_id") }
  end

  test "run starts one execution now without moving the clock and refuses while it is unfinished" do
    job = create_job
    occurrence = job.next_run_at
    assert_difference -> { Conversation.count }, 1 do
      post "#{jobs_path}/#{job.public_id}/run", headers: auth
      assert_response :success
    end
    row = response.parsed_body.fetch("schedule")
    assert_equal "active", row.fetch("status")
    assert_equal occurrence, job.reload.next_run_at, "the rule's occurrence is untouched"
    assert_in_delta occurrence, Time.iso8601(row.fetch("next_run_at")), 1
    assert_equal "queued", row.dig("last_execution", "status")
    child = job.last_execution_conversation
    assert_equal child.public_id, row.dig("last_execution", "child_conversation_public_id")
    assert_in_delta Time.current, child.scheduled_for, 5.seconds
    assert_nil row.fetch("last_error_code")

    post "#{jobs_path}/#{job.public_id}/run", headers: auth
    assert_response :conflict
    assert_equal "execution_in_progress", response.parsed_body.dig("error", "code")

    post "#{jobs_path}/#{job.public_id}/cancel", headers: auth
    assert_response :success
    post "#{jobs_path}/#{job.public_id}/run", headers: auth
    assert_response :unprocessable_entity
    assert_equal "schedule_finished", response.parsed_body.dig("error", "code")
  end

  test "run runs a paused job once and needs write standing" do
    job = create_job
    post "#{jobs_path}/#{job.public_id}/pause", headers: auth
    assert_response :success
    post "#{jobs_path}/#{job.public_id}/run", headers: auth
    assert_response :success
    assert_equal "paused", response.parsed_body.dig("schedule", "status")
    assert_nil response.parsed_body.dig("schedule", "next_run_at")
    assert_equal 1, job.reload.execution_conversations.count

    @token = create_access_token_fixture(user: users(:curator), name: "Reader")
    @conversation.update!(access_default: "read")
    post "#{jobs_path}/#{job.public_id}/run", headers: auth
    assert_response :forbidden
    assert_equal 1, job.reload.execution_conversations.count
  end

  test "a scoped miss stays absent and read-only members cannot create or edit" do
    job = create_job
    other = create_conversation!
    get "#{conversation_path(other)}/schedules/#{job.public_id}", headers: auth
    assert_response :not_found

    reader = users(:curator)
    @token = create_access_token_fixture(user: reader, name: "Reader")
    @conversation.update!(access_default: "read")
    get jobs_path, headers: auth
    assert_response :success
    assert_equal [job.public_id], response.parsed_body.fetch("schedules").map { |row| row.fetch("public_id") }
    post jobs_path, headers: auth("denied"), params: { schedule: fields }, as: :json
    assert_response :forbidden
    post "#{jobs_path}/#{job.public_id}/pause", headers: auth
    assert_response :forbidden
  end

  test "invalid rules and a malformed tool restriction have no durable effect" do
    assert_no_difference("Schedule.count") do
      post jobs_path, headers: auth("bad-rule"), as: :json,
        params: { schedule: fields.merge(rule: { kind: "daily", local_time: "25:00", time_zone: "Moon" }) }
      assert_response :unprocessable_entity
      post jobs_path, headers: auth("bad-tools"), as: :json,
        params: { schedule: fields.merge(tool_names: "read_file") }
      assert_response :bad_request
    end
  end

  test "last execution follows the child's current visibility on both job reads and execution history" do
    job = create_job
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: @at)
    child = job.reload.last_execution_conversation
    @token = create_access_token_fixture(user: users(:curator), name: "Scheduled reader")
    get "#{jobs_path}/#{job.public_id}", headers: auth
    assert_response :success
    assert_equal child.public_id, response.parsed_body.dig("schedule", "last_execution", "child_conversation_public_id")

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
    assert_equal child.public_id, response.parsed_body.dig("schedule", "last_execution", "child_conversation_public_id")

    child.update!(tombstoned_at: Time.current)
    assert_execution_hidden(job)
  end

  test "list and executions use bounded opaque pagination with a durable run checkpoint" do
    jobs = 3.times.map { create_job }
    get jobs_path, headers: auth, params: { limit: 2 }
    assert_response :success
    first = response.parsed_body
    assert_equal 2, first.fetch("schedules").length
    cursor = first.dig("pagination", "next_after")
    assert cursor
    get jobs_path, headers: auth, params: { limit: 2, after: cursor }
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("schedules").length

    job = jobs.first
    assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: @at)
    get "#{jobs_path}/#{job.public_id}/executions", headers: auth
    assert_response :success
    execution = response.parsed_body.fetch("executions").sole
    assert_equal Nexus::Contract.pack.fetch("schedules.json").fetch("execution_projection").sort, execution.keys.sort
    assert_equal "queued", execution.fetch("status")
    assert_equal job.reload.last_execution_conversation.public_id, execution.fetch("child_conversation_public_id")
    assert_nil execution["run_public_id"]
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
      assert_nil response.parsed_body.fetch("schedule").fetch("last_execution")
      get jobs_path, headers: auth
      assert_response :success
      assert_nil response.parsed_body.fetch("schedules").sole.fetch("last_execution")
      get "#{jobs_path}/#{job.public_id}/executions", headers: auth
      assert_response :success
      assert_empty response.parsed_body.fetch("executions")
    end

    def jobs_path = "#{conversation_path(@conversation)}/schedules"
    def workspace_jobs_path = "/agent_api/v1/workspaces/#{@workspace.public_id}/schedules"

    def fields
      { name: "Check mail", prompt: "Check mail and report", model: { model: "dev/mock-text" },
        tool_names: [], rule: { kind: "once", run_at: @at.iso8601(6) } }
    end

    def create_job
      post jobs_path, headers: auth(SecureRandom.uuid), params: { schedule: fields }, as: :json
      assert_response :created
      @conversation.schedules.find_by!(public_id: response.parsed_body.dig("schedule", "public_id"))
    end
end
