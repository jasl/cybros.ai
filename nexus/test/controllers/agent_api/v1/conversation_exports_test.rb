require "test_helper"
require "zlib"
require_relative "../../../test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationExportsTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    @reader = create_access_token_fixture(user: users(:curator), name: "Export reader")
    Accounts::ConfigureCostUnit.call(account: @account, cost_unit: "USD")
  end

  test "an empty conversation downloads a complete UTF-8 gzip document through the member read plane" do
    @conversation.update!(title: "诊断记录", metadata: { "password" => "opaque application data" })

    get export_path, headers: auth

    assert_response :success
    assert_equal "application/gzip", response.media_type
    assert_equal "no-store", response.headers.fetch("Cache-Control")
    assert_includes response.headers.fetch("Content-Disposition"), "attachment"
    assert_includes response.headers.fetch("Content-Disposition"), "conversation-#{@conversation.public_id}.jsonl.gz"
    assert_nil response.headers["Content-Encoding"]
    assert_nil response.headers["ETag"]
    assert_equal [0x1f, 0x8b], response.body.bytes.take(2)
    records = decode_export
    assert_equal %w[export conversation end], records.pluck("type")
    assert_equal "nexus.conversation.diagnostic", records.first.fetch("format")
    assert_equal 1, records.first.fetch("version")
    assert_equal "observation_interval", records.first.fetch("consistency")
    assert_equal @conversation.public_id, records.first.fetch("conversation_public_id")
    assert_equal "诊断记录", records.second.dig("conversation", "title")
    assert_equal({ "password" => "opaque application data" }, records.second.dig("conversation", "metadata"))
    assert_equal records.pluck("type").tally, records.last.fetch("counts")
    assert records.last.fetch("completed_at")
  end

  test "read and full standing include archived resources while none and tombstones remain absent" do
    %w[full read].each do |level|
      @conversation.update!(access_default: level)
      get export_path, headers: reader_headers
      assert_response :success
      assert_equal @conversation.public_id, decode_export.second.dig("conversation", "public_id")
    end

    @conversation.update!(archived_at: Time.current)
    @workspace.update!(state: "archived", archived_at: Time.current)
    get export_path, headers: reader_headers
    assert_response :success
    assert decode_export.second.dig("conversation", "archived_at")

    @conversation.update!(access_default: "none")
    get export_path, headers: reader_headers
    assert_response :not_found
    @conversation.update!(access_default: "full", tombstoned_at: Time.current)
    get export_path, headers: auth
    assert_response :not_found
  end

  test "a wrong Workspace missing credential and executor or Platform credential cannot export" do
    get export_path(@conversation, workspace: workspaces(:personal)), headers: reader_headers
    assert_response :not_found
    get export_path
    assert_response :unauthorized
    platform = create_access_token_fixture(user: @human, name: "Platform", plane: :platform)
    get export_path, headers: { "Authorization" => "Bearer #{platform.secret}" }
    assert_response :unauthorized
    get export_path, headers: { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }
    assert_response :unauthorized

    @workspace.update!(state: "deleted", deleted_at: Time.current)
    get export_path, headers: auth
    assert_response :not_found
  end

  test "queued inputs and every live candidate retain their own public identities and attachment descriptors" do
    turn = materialize_message(@conversation, "original words")
    original = turn.active_variant
    edited = edit_message(@conversation, turn, "second candidate")
    active = edit_message(@conversation, turn, "third candidate")
    patch "#{turn_path(@conversation, turn)}/variants/#{edited}", headers: auth, as: :json,
      params: { variant: { concealed: true } }
    assert_response :success
    picture = @account.content_uploads.create!(creating_user: @human,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(PngFixture.bytes(width: 2, height: 2)),
        filename: "diagram.png", content_type: "image/png"))
    post inputs_path(@conversation), headers: auth("queued"), as: :json,
      params: { input: { text: "queued words", attachments: [picture.public_id] } }
    assert_response :accepted
    expected_input = response.parsed_body.fetch("input")
    downloads = []
    subscription = ActiveSupport::Notifications.subscribe(/service_download.*\.active_storage/) do |name, *|
      downloads << name
    end

    get export_path, headers: auth

    assert_response :success
    records = decode_export
    assert_equal [expected_input], projections(records, "input")
    assert_equal turn.input_public_id, projections(records, "turn").sole.fetch("input_public_id")
    assert_equal [original.public_id, active], projections(records, "variant").pluck("public_id")
    assert_equal ["original words", "third candidate"], projections(records, "variant").pluck("content")
    assert_equal [picture.public_id], projections(records, "input").sole.fetch("attachments").pluck("public_id")
    assert_empty projections(records, "execution_unavailable")
    assert_empty downloads, "the archive carries attachment descriptors without reading stored bytes"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "a completed tool reply exports retained steers results graph requests usage and events without bearer fields" do
    declare_tools!(@agent)
    @conversation.update!(metadata: { "token" => "an application token label" })
    turn, run = materialize_loop_reply!(@conversation, agent: @human, text: "Inspect the export", model_ref: "mock-priced")
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Inspecting", tool_calls: [
      { id: "read", name: "read_file", arguments: { path: "notes", password: "opaque input" }.to_json },
    ], usage: { "input_tokens" => 10, "output_tokens" => 4 }))
    steer = post_input!(@conversation, acting_user: @human, text: "Include the evidence", delivery_mode: "steer")
    task = loop_node(run, "r2t0")
    executor = Executor.address_for(@agent)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(run: run, task_key: task.node_key, executor: executor))
    assert_predicate claimed, :accepted?, claimed.outcome.inspect
    secret = claimed.value.claim_token
    committed = Executors::Commit.call(Executors::Commit::Command.new(
      run: run, task_key: task.node_key, executor: executor, claim_token: secret,
      content: "retained tool result", structured_content: false, result_type: nil,
      outcome: "completed", is_error: false, title: "Evidence", metadata: { "secret" => "opaque result metadata" }
    ))
    assert_predicate committed, :applied?, committed.outcome.inspect
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Final answer", usage: { "input_tokens" => 20, "output_tokens" => 6 }))
    Conversations::Turns::Converge.call
    assert_equal "completed", turn.reload.status
    assert_not Input.exists?(steer.id)

    get export_path, headers: reader_headers

    assert_response :success
    records = decode_export
    assert_equal [run.public_id], projections(records, "run").pluck("public_id")
    variants = projections(records, "variant")
    assert_equal "Inspect the export", variants.sole.fetch("prompt_text")
    assert_includes variants.sole.fetch("content"), "Final answer"
    assert_includes records.select { |record| record.fetch("type") == "steer" }.to_json, "Include the evidence"
    exported_task = projections(records, "task").find { |row| row.fetch("key") == task.node_key }
    assert_equal "retained tool result", exported_task.fetch("output")
    assert_equal false, exported_task.fetch("structured_content")
    assert_equal({ "secret" => "opaque result metadata" }, exported_task.fetch("metadata"))
    assert_equal({ "path" => "notes", "password" => "opaque input" }, exported_task.fetch("tool_input"))
    assert_equal "r1", exported_task.fetch("declaring_task_key")
    assert_equal AgentAPI::RunGraphPresenter.call(run.reload).to_h.fetch(:nodes).as_json.sort_by { |node| node.fetch("key") },
      projections(records, "graph_node", key: "node").sort_by { |node| node.fetch("key") }
    assert_equal AgentAPI::RunGraphPresenter.call(run).to_h.fetch(:edges).as_json.sort_by { |edge| edge.values_at("from", "to") },
      projections(records, "graph_edge", key: "edge").sort_by { |edge| edge.values_at("from", "to") }
    requests = records.select { |record| record.fetch("type") == "request" }
    assert_includes requests.to_json, "Inspect the export"
    assert_includes requests.to_json, "retained tool result"
    receipt_rows = UsageRecord.where(conversation_public_id: @conversation.public_id).order(:id).to_a
    usage = projections(records, "usage")
    assert_equal receipt_rows.map(&:public_id), usage.pluck("usage_record_public_id")
    assert_equal receipt_rows.map { |row| row.cost_amount.to_s("F") }, usage.pluck("cost_amount")
    assert_equal [30, 10, 40], %w[input_tokens output_tokens total_tokens].map { |field| usage.sum { |row| row.fetch(field) } }
    assert_equal 2, usage.length
    assert_equal @conversation.event_items.order(:sequence).map { |item| EventItem::PublicProjection.render(item).as_json },
      projections(records, "event")
    json = records.to_json
    [secret, @token.secret, @reader.secret].each { |credential| assert_not_includes json, credential }
    %w[claim_token resolution_token secret_digest provider_usage account_id].each do |field|
      assert_not_includes json, "\"#{field}\":"
    end
    records.each do |record|
      %w[conversation_id turn_id variant_id run_id model_invocation_id].each { |field| assert_not record.key?(field) }
    end
  end

  test "an authored ask resolution capability is not part of a readable task export" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    grow!(seam.run, ask("decision"))
    token = seam.run.tasks.find_by!(node_key: "decision").resolution_token
    assert token

    get export_path, headers: reader_headers

    assert_response :success
    records = decode_export
    assert_equal ["decision"], projections(records, "task").pluck("key")
    assert_not_includes records.to_json, token
    assert_not projections(records, "task").sole.key?("resolution_token")
  end

  test "task detail retains the existing declaring round through tool expansion and structural fallback" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    round = seam.run.tasks.create!(type: Tasks::ModelTask.sti_name, node_key: "round", authored_by: "author",
      provider_id: "dev", model_ref: "mock-text")
    parent = seam.run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "parent", authored_by: "author",
      tool_name: "read_file", tool_input: {}, expansion_parent: round)
    nested = seam.run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "nested", authored_by: "author",
      tool_name: "read_file", tool_input: {}, expansion_parent: parent)
    fallback = seam.run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "fallback", authored_by: "author",
      tool_name: "read_file", tool_input: {})
    seam.run.run_edges.create!(from_node: round, to_node: fallback, structural: true)

    get export_path, headers: auth

    assert_response :success
    details = projections(decode_export, "task").index_by { |task| task.fetch("key") }
    [parent, nested, fallback].each do |task|
      assert_equal Runs::KernelTool.round_of(task).node_key, details.fetch(task.node_key).fetch("declaring_task_key")
    end
  end

  test "fork view overrides govern structured content while event replay keeps its retained previews" do
    first, hidden, concealed, boundary = %w[first hidden concealed boundary].map do |text|
      materialize_message(@conversation, text)
    end
    fork = fork_at(boundary)
    update_turn(@conversation, first, visibility: "hidden")
    update_turn(fork, hidden, visibility: "hidden")
    update_turn(fork, concealed, concealed: true)
    update_turn(fork, first, visibility: "excluded_from_context")

    get export_path(fork), headers: auth

    assert_response :success
    records = decode_export
    turns = projections(records, "turn")
    assert_equal [first.public_id, hidden.public_id, fork.turns.sole.public_id], turns.pluck("public_id")
    assert_equal %w[excluded_from_context hidden visible], turns.pluck("visibility")
    assert_equal [true, true, false], turns.pluck("inherited")
    assert_not_includes projections(records, "variant").pluck("public_id"), concealed.active_variant.public_id
    assert_empty projections(records, "execution_unavailable")

    update_turn(@conversation, hidden, concealed: true)
    get export_path, headers: auth
    records = decode_export
    assert_not_includes projections(records, "turn").pluck("public_id"), hidden.public_id
    assert_equal @conversation.event_items.order(:sequence).map { |item| EventItem::PublicProjection.render(item).as_json },
      projections(records, "event")
  end

  test "an inherited request stays readable while an inaccessible source Run contributes no execution or receipts" do
    declare_tools!(@agent)
    turn, run = complete_reply
    fork = fork_at(materialize_message(@conversation, "fork boundary"))

    get export_path(fork), headers: reader_headers
    assert_response :success
    assert_equal [run.public_id], projections(decode_export, "run").pluck("public_id")

    @conversation.reload.update!(access_default: "none")
    get export_path(fork), headers: reader_headers
    assert_response :success
    records = decode_export
    assert_includes projections(records, "variant").to_json, "retained answer"
    assert_empty projections(records, "run")
    assert_empty projections(records, "task")
    assert_empty projections(records, "graph_node", key: "node")
    assert_empty projections(records, "usage")
    missing = records.select { |record| record.fetch("type") == "execution_unavailable" }.sole
    assert_equal turn.active_variant.public_id, missing.fetch("variant_public_id")
    assert_equal "unavailable", missing.fetch("reason")
    requests = records.select { |record| record.fetch("type") == "request" }
    assert_equal [turn.active_variant.public_id], requests.pluck("variant_public_id")
    assert requests.none? { |record| record.key?("task_key") }
    assert_nil projections(records, "conversation").sole["source_conversation_public_id"]
  end

  test "execution collection keeps prompt answer and exact receipts while reporting missing detail" do
    declare_tools!(@agent)
    turn, run = complete_reply
    receipt = UsageRecord.find_by!(conversation_public_id: @conversation.public_id)
    run.update!(completed_at: 100.days.ago)
    assert_equal 1, Conversations::ExecutionDetails::Prune.call(account: @account, batch: 10)[:pruned]

    get export_path, headers: auth

    assert_response :success
    records = decode_export
    assert_equal "retained question", projections(records, "variant").sole.fetch("prompt_text")
    assert_includes projections(records, "variant").sole.fetch("content"), "retained answer"
    assert_empty projections(records, "task")
    assert_empty projections(records, "request")
    missing = records.select { |record| record.fetch("type") == "execution_unavailable" }.sole
    assert_equal turn.active_variant.public_id, missing.fetch("variant_public_id")
    assert_equal "execution_details_pruned", missing.fetch("reason")
    assert_equal receipt.public_id, projections(records, "usage").sole.fetch("usage_record_public_id")
    assert_equal receipt.cost_amount.to_s("F"), projections(records, "usage").sole.fetch("cost_amount")
  end

  test "child conversation content and spending remain outside its parent's export" do
    declare_tools!(@agent)
    parent_turn, = complete_reply
    child = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent,
      parent_conversation: @conversation, parent_conversation_public_id: @conversation.public_id, spawn_label: "worker")
    child_turn, = complete_reply(conversation: child)
    parent_receipt = UsageRecord.find_by!(conversation_public_id: @conversation.public_id)
    child_receipt = UsageRecord.find_by!(conversation_public_id: child.public_id)

    get export_path, headers: auth

    assert_response :success
    records = decode_export
    assert_equal [parent_turn.public_id], projections(records, "turn").pluck("public_id")
    assert_not_includes projections(records, "variant").pluck("public_id"), child_turn.active_variant.public_id
    assert_equal [parent_receipt.public_id], projections(records, "usage").pluck("usage_record_public_id")
    assert_not_includes records.to_json, child_receipt.public_id
  end

  test "a Side exports its frozen reference without inventing source execution or recursive content" do
    declare_tools!(@agent)
    settled = materialize_message(@conversation, "settled prefix")
    _turn, run = materialize_loop_reply!(@conversation, agent: @human, text: "unfinished question")
    schedule_loop!(run)
    side = Conversations::Fork.call(Conversations::Fork::Command.new(
      conversation: @conversation.reload, turn_public_id: nil, variant_public_id: nil,
      acting_user: @human, title: nil, side: true
    ))
    assert_predicate side, :accepted?, side.outcome.inspect
    side = side.value
    update_turn(side, settled, visibility: "hidden")
    reference = side.turns.sole

    get export_path(side), headers: auth

    assert_response :success
    records = decode_export
    assert_equal [settled.public_id, reference.public_id], projections(records, "turn").pluck("public_id")
    assert_equal "hidden", projections(records, "turn").first.fetch("visibility")
    assert_equal true, projections(records, "turn").last.fetch("reference")
    assert_empty projections(records, "run")
    assert_empty projections(records, "execution_unavailable")
    assert_empty projections(records, "usage")
    get export_path, headers: auth
    assert_not_includes projections(decode_export, "turn").pluck("public_id"), reference.public_id
  end

  test "task and graph pages stay bounded and avoid per-task queries while exporting every endpoint once" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    seed_task_rows(seam.run, 0...10)
    get export_path, headers: auth
    assert_response :success
    small = sql_count { get export_path, headers: auth }
    seed_task_rows(seam.run, 10...90)
    same_page = sql_count { get export_path, headers: auth }
    assert_response :success
    assert_operator same_page, :<=, small + 5, "adding tasks within one page must not add one query per task"
    seed_task_rows(seam.run, 90...(AgentAPI::ConversationExport::PAGE_SIZE + 3))
    rows = seam.run.tasks.order(:node_key).to_a
    RunEdge.insert_all!(rows.each_cons(2).map do |source, target|
      { account_id: @account.id, run_id: seam.run.id, from_node_id: source.id, to_node_id: target.id, structural: true }
    end)
    loads = []
    subscriber = ->(*, payload) do
      loads << payload.fetch(:record_count) if %w[Task RunEdge].include?(payload.fetch(:class_name))
    end

    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      get export_path, headers: auth
    end

    assert_response :success
    records = decode_export
    expected = rows.map(&:node_key)
    assert_equal expected, projections(records, "task").pluck("key")
    assert_equal expected, projections(records, "graph_node", key: "node").pluck("key")
    assert_equal expected.each_cons(2).to_a,
      projections(records, "graph_edge", key: "edge").map { |edge| edge.values_at("from", "to") }
    assert_operator loads.max, :<=, AgentAPI::ConversationExport::PAGE_SIZE
  end

  private

    def export_path(conversation = @conversation, workspace: @workspace)
      "/agent_api/v1/workspaces/#{workspace.public_id}/conversations/#{conversation.public_id}/export"
    end

    def reader_headers = { "Authorization" => "Bearer #{@reader.secret}" }

    def decode_export
      jsonl = Zlib::GzipReader.wrap(StringIO.new(response.body), &:read).force_encoding(Encoding::UTF_8)
      assert_predicate jsonl, :valid_encoding?
      assert jsonl.end_with?("\n")
      records = jsonl.lines.map { |line| JSON.parse(line) }
      assert_equal "export", records.first.fetch("type")
      assert_equal "end", records.last.fetch("type")
      assert_equal records.pluck("type").tally, records.last.fetch("counts")
      records
    end

    def projections(records, type, key: type)
      records.filter_map { |record| record.fetch(key) if record.fetch("type") == type }
    end

    def materialize_message(conversation, text)
      post inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json, params: { input: { text: text } }
      assert_response :accepted
      input_id = response.parsed_body.dig("input", "public_id")
      perform_enqueued_jobs only: Conversations::Inputs::DrainJob
      conversation.turns.find_by!(input_public_id: input_id)
    end

    def edit_message(conversation, turn, text)
      post "#{turn_path(conversation, turn)}/edit", headers: auth, as: :json, params: { edit: { text: text } }
      assert_response :success
      response.parsed_body.dig("variant", "public_id")
    end

    def turn_path(conversation, turn) = "#{turns_path(conversation)}/#{turn.public_id}"

    def update_turn(conversation, turn, **fields)
      patch turn_path(conversation, turn), headers: auth, as: :json, params: { turn: fields }
      assert_response :success
    end

    def fork_at(turn)
      post conversation_forks_path(@conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { fork: { turn_public_id: turn.public_id } }
      assert_response :created
      Conversation.find_by!(public_id: response.parsed_body.dig("conversation", "public_id"))
    end

    def complete_reply(conversation: @conversation)
      turn, run = materialize_loop_reply!(conversation, agent: @human,
        text: "retained question", model_ref: "mock-priced")
      schedule_loop!(run)
      run_loop_round!(run, sse_success("retained answer", usage: { "input_tokens" => 10, "output_tokens" => 4 }))
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
      [turn, run]
    end

    def seed_task_rows(run, positions)
      Task.insert_all!(positions.map do |index|
        { account_id: @account.id, run_id: run.id, node_key: format("task-%04d", index),
          type: Tasks::ModelTask.sti_name, status: "completed", authored_by: "author",
          provider_id: "dev", model_ref: "mock-text",
          model_selection: ModelSelectionIntent.default("dev/mock-text").as_json }
      end)
    end
end
