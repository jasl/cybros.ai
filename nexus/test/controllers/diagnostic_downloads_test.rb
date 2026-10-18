require "test_helper"
require "zlib"

class DiagnosticDownloadsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: users(:agent))
    @window = { from: "2026-10-10T12:15:30.123456Z", to: "2026-10-12T12:15:30.654321Z" }
    sign_in_as @human
  end

  test "work export includes exact receipt evidence only for currently readable Conversations" do
    visible = receipt(@conversation, cost: nil)
    hidden = Conversation.create!(workspace: @workspace, creating_user: users(:owner), access_default: "none")
    receipt(hidden, cost: 99)
    get usage_export_path, params: @window.merge(workspace_public_id: @workspace.public_id)
    records = decode
    assert_equal [visible.public_id], records.select { |row| row["type"] == "usage" }
      .map { |row| row.dig("usage", "usage_record_public_id") }
    summary = records.find { |row| row["type"] == "summary" }.fetch("report")
    assert_equal @window[:from], summary.fetch("from")
    assert_equal @window[:to], summary.fetch("to")
    assert_equal 1, summary.dig("model_usage", "totals", "request_count")
    assert_equal false, summary.dig("model_usage", "totals", "cost_complete")
    assert_not_includes records.to_json, hidden.public_id
    assert_not_includes records.to_json, "payer_user_public_id"
    get usage_export_path, params: @window.merge(workspace_public_id: workspaces(:personal).public_id)
    assert_response :not_found
  end

  test "admin downloads aggregates without content or member attribution and reject activity selectors" do
    receipt(@conversation, cost: 3)
    get admin_model_usage_export_path, params: @window
    assert_response :forbidden
    sign_out
    sign_in_as users(:owner)
    get admin_model_usage_export_path, params: @window
    records = decode
    assert_equal %w[export summary end], records.pluck("type")
    assert_equal "account_aggregate", records.first.fetch("scope")
    assert_not_includes records.to_json, @conversation.public_id
    assert_not_includes records.to_json, @human.public_id
    assert_not_includes records.to_json, "execution"
    %w[workspace_public_id agent_public_id consumer_user_public_id payer_user_public_id billing_subject].each do |key|
      get admin_model_usage_export_path, params: @window.merge(key => @human.public_id)
      assert_response :bad_request
    end
  end

  test "receipt pagination preserves same-time rows and does not apply the summary group limit to evidence" do
    expected = (DiagnosticExport::PAGE_SIZE + 1).times.map do |index|
      receipt(@conversation, cost: index.zero? ? nil : 0).public_id
    end
    receipt(@conversation, cost: 1, consumer: users(:member))
    get usage_export_path, params: @window.merge(agent_public_id: users(:agent).public_id, limit: 1)
    records = decode
    assert_equal expected, records.select { |row| row["type"] == "usage" }
      .map { |row| row.dig("usage", "usage_record_public_id") }
    totals = records.find { |row| row["type"] == "summary" }.dig("report", "model_usage", "totals")
    assert_equal expected.length, totals.fetch("request_count")
    assert_equal false, totals.fetch("cost_complete")
  end

  test "Run export keeps retained tasks and marks collected execution without granting owner bypass" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    task = seam.run.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: "tool", authored_by: "author",
      tool_name: "read", tool_input: { "path" => "notes" })
    get run_export_path(seam.run)
    records = decode
    assert_equal "nexus.run.diagnostic", records.first.fetch("format")
    assert_equal task.node_key, records.find { |row| row["type"] == "task" }.dig("task", "key")
    assert_equal({ "path" => "notes" }, records.find { |row| row["type"] == "task" }.dig("task", "tool_input"))
    seam.run.update!(details_pruned_at: Time.current)
    get run_export_path(seam.run)
    assert_equal "execution_details_pruned", decode.find { |row| row["type"] == "execution_unavailable" }.fetch("reason")
    @conversation.update!(access_default: "none")
    sign_out
    sign_in_as users(:owner)
    get run_export_path(seam.run)
    assert_response :not_found
  end

  test "Workspace data exports opaque values and current documents within existing access" do
    @workspace.store_entries.create!(account: accounts(:cybros), namespace: "application.presets", key: "opaque", value: { "token" => "application data" })
    PromptDocuments::Write.call(anchor: { workspace: @workspace }, slot: "character", content: "Shared text", role: "system")
    anchor = Scopes::Anchor.call(path: "workspace/notes", workspace: @workspace)
    result = MemoryDocuments::Write.call(anchor: anchor, content: "Remember this", expected: nil)
    assert_predicate result, :written?
    get workspace_data_export_path(@workspace)
    records = decode
    assert_equal({ "token" => "application data" }, records.find { |row| row["type"] == "store_entry" }.dig("store_entry", "value"))
    assert_equal "Remember this", records.find { |row| row["type"] == "memory" }.dig("memory", "content")
    assert_equal "Shared text", records.find { |row| row["type"] == "prompt_document" }.dig("prompt_document", "content")
    get workspace_data_export_path(workspaces(:personal))
    assert_response :not_found
  end

  test "memory override exports only the skill exception and marks the unavailable memory" do
    %w[notes skills/review].each do |name|
      anchor = Scopes::Anchor.call(path: "workspace/#{name}", workspace: @workspace)
      result = MemoryDocuments::Write.call(anchor: anchor, content: name, expected: nil,
        description: ("Review instructions" if name.start_with?("skills/")))
      assert_predicate result, :written?
    end
    provider = connect_provider(identifier: "export-memory", tools: Nexus::ToolRegistry.wire_names_in("nexus.memory"))
    @workspace.update!(tool_provider_overrides: { "nexus.memory" => provider.public_id })
    get workspace_data_export_path(@workspace)
    records = decode
    assert_equal "memory_overridden", records.find { |row| row["type"] == "memory_unavailable" }.fetch("reason")
    assert_equal ["workspace/skills/review"], records.select { |row| row["type"] == "memory" }.map { |row| row.dig("memory", "path") }
  end

  private

    def receipt(conversation, cost:, consumer: users(:agent))
      UsageRecord.create!(account: accounts(:cybros), idempotency_key: SecureRandom.uuid_v7,
        model_invocation_public_id: SecureRandom.uuid_v7, attempt_ordinal: 1,
        conversation_public_id: conversation.public_id, workspace_public_id: conversation.workspace.public_id,
        consumer_user_public_id: consumer.public_id, payer_user_public_id: @human.public_id,
        provider_id: "dev", catalog_model_ref: "dev/text", wire_model_id: "text", workload: "text_generation",
        purpose: "task", service_class: "interactive", admission_shape: "priced", status: "succeeded",
        recorded_at: Time.utc(2026, 10, 11), total_tokens: 12, cost_amount: cost, cost_unit: "USD")
    end

    def decode
      assert_response :success
      assert_equal "application/gzip", response.media_type
      assert_equal "no-store", response.headers["Cache-Control"]
      records = Zlib::GzipReader.wrap(StringIO.new(response.body), &:read).lines.map { |line| JSON.parse(line) }
      assert_equal "end", records.last.fetch("type")
      assert_equal records.pluck("type").tally, records.last.fetch("counts")
      records
    end
end
