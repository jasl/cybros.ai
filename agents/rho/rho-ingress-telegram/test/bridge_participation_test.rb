require_relative "test_helper"
require "support/bridge"

class TelegramBridgeParticipationTest < Minitest::Test
  include TelegramBridgeSupport

  Result = Data.define(:output_text, :finish_quality, :files, :error)
  Shot = Data.define(:public_id, :status, :result)
  AcceptedShot = Data.define(:inference_request)
  AcceptedInput = Data.define(:input)
  ModelConfiguration = Data.define(:default_model)
  ModelProfile = Data.define(:configuration)
  InputWriter = Data.define(:calls, :materialized) do
    def create(**fields)
      calls << [:input, fields]
      AcceptedInput.new(input: Parent.new(public_id: "recorded-input"))
    end

    def materialization(id, include_hidden:)
      calls << [:materialization, id, include_hidden]
      materialized
    end
  end

  class Client
    attr_reader :calls
    attr_accessor :shot, :event_pages, :configuration, :materialization

    def initialize
      @calls, @event_pages = [], {}
      @configuration = ModelConfiguration.new(default_model: "dev/default-text")
    end

    def workspace(id)
      @calls << [:workspace, id]
      self
    end

    def conversation(id)
      @calls << [:conversation, id]
      self
    end

    def inputs = InputWriter.new(calls: @calls, materialized: @materialization)
    def profile = self
    def inference_requests = self

    def create(**fields)
      @calls << [:inference_request, fields]
      AcceptedShot.new(inference_request: @shot)
    end

    def fetch(id = nil)
      @calls << [:fetch, id]
      id ? @shot : ModelProfile.new(configuration: @configuration)
    end

    def cancel(id)
      @calls << [:cancel, id]
      @shot
    end

    def events(after:)
      @calls << [:events, after]
      @event_pages.fetch(after)
    end
  end

  def setup
    @core, @client = Core.new, Client.new
    @host = Host.new(home: nil, member_plane: ->(require_workspace:, host_public_id: nil, workspace_public_id: nil) do
      Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: workspace_public_id || "default-workspace")
    end)
    @bridge = Rho::IngressTelegram::Bridge.new(host: @host, core: @core)
    @position = { "cursor" => "c7", "sequence" => 7 }
  end

  def test_participation_creates_one_toolless_call_with_the_frozen_envelope
    @client.shot = Shot.new(public_id: "decision", status: "queued", result: nil)
    fields = { prompt: "Decide from this frozen group context.", model: "dev/chosen-text", configuration: {},
      idempotency_key: "telegram:room:source", workspace_public_id: "original" }

    2.times do
      assert_equal({ "id" => "decision", "status" => "queued" }, @bridge.participation_start(**fields))
    end

    calls = @client.calls.select { |call| call.first == :inference_request }
    assert_equal 2, calls.length
    assert_equal calls.first, calls.last, "a retry retains its exact prompt, model, configuration and key"
    assert_equal [:inference_request, { workload: "text_generation", model: "dev/chosen-text",
      input: fields.fetch(:prompt), configuration: {}, idempotency_key: "telegram:room:source" }], calls.first
    assert_equal [[:workspace, "original"], [:workspace, "original"]], @client.calls.select { |call| call.first == :workspace }
    assert_empty @core.calls, "a participation decision starts no conversation execution"
  end

  def test_participation_read_preserves_truncation_and_failure_instead_of_claiming_a_complete_answer
    @client.shot = Shot.new(public_id: "decision", status: "completed",
      result: Result.new(output_text: '{"decision":"reply","text":"Hello"}',
        finish_quality: "output_budget_exhausted", files: [], error: nil))

    row = @bridge.participation(id: "decision", workspace_public_id: "original")

    assert_equal "completed", row.fetch("status")
    assert_equal "output_budget_exhausted", row.fetch("finish_quality")
    assert_equal @client.shot.result.output_text, row.fetch("text")
    assert_equal [[:workspace, "original"], [:fetch, "decision"]], @client.calls

    @client.shot = @client.shot.with(status: "failed", result: @client.shot.result.with(
      output_text: nil, finish_quality: "refused", error: Data.define(:code).new(code: "model_refused")))
    row = @bridge.participation(id: "decision", workspace_public_id: "original")
    assert_equal "failed", row.fetch("status")
    assert_equal "model_refused", row.fetch("error")
    refute row.key?("text")
  end

  def test_participation_cancel_addresses_only_the_original_inference_request
    @client.shot = Shot.new(public_id: "old-decision", status: "running", result: nil)

    assert_nil @bridge.cancel_participation(id: "old-decision", workspace_public_id: "original")

    assert_equal [[:workspace, "original"], [:cancel, "old-decision"]], @client.calls
    assert_empty @core.calls, "canceling a candidate must not stop a conversation or another member's task"
  end

  def test_sent_participation_is_recorded_as_the_members_own_assistant_message_without_new_execution
    id = @bridge.record_participation("observer", text: "A useful short reply", idempotency_key: "sent:42",
      workspace_public_id: "original")

    assert_equal "recorded-input", id
    assert_equal [[:workspace, "original"], [:conversation, "observer"], [:input, {
      kind: "message", role: "assistant", text: "A useful short reply", delivery_mode: "queue", idempotency_key: "sent:42",
    }]], @client.calls
    assert_empty @core.calls, "recording sent speech supplies neither a model nor an ingress speaker"
  end

  def test_participation_model_reads_only_the_connected_profiles_declared_default
    assert_equal "dev/default-text", @bridge.participation_model
    @client.configuration = ModelConfiguration.new(default_model: nil)
    assert_nil @bridge.participation_model
    @client.configuration = nil
    assert_nil @bridge.participation_model
    assert_empty @core.calls
  end

  def test_participation_memory_keeps_the_kernel_selection_without_replaying_group_history
    entries = [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "Shared release fact" }] }]
    preview = { "memory" => { "included" => 1 }, "entries" => entries }
    calls = @core.calls
    @core.define_singleton_method(:prompt_preview) do |id, **fields|
      calls << [:prompt_preview, id, fields]
      preview
    end

    text = @bridge.participation_memory("group-memory", model: "dev/chosen-text", workspace_public_id: "original")

    assert_equal entries, JSON.parse(text.lines.drop(1).join)
    _, id, fields = calls.fetch(0)
    assert_equal "group-memory", id
    assert_equal "dev/chosen-text", fields.fetch(:model)
    assert_equal "original", fields.fetch(:workspace_public_id)
    blocks = fields.fetch(:template).fetch("blocks")
    assert_equal %w[memory history input], blocks.map { |block| block.fetch("type") }
    assert_equal({ "max_tokens" => 0 }, blocks.fetch(1).fetch("budget"))
    refute fields.key?(:prompt), "the observation window is supplied separately to the InferenceRequest"
  end

  def test_participation_without_selected_memory_adds_no_empty_reference_block
    @core.define_singleton_method(:prompt_preview) do |*, **|
      { "memory" => { "included" => 0 }, "entries" => [] }
    end

    assert_nil @bridge.participation_memory("group-memory", model: "dev/chosen-text", workspace_public_id: "original")
  end

  def test_participation_context_waits_for_its_exact_input_to_materialize
    @client.event_pages["c7"] = page([], watermark: 7)
    @core.turn_rows = [turn("old-turn", text: "Older context")]

    assert_nil context
    assert_empty @core.calls, "an accepted input is not proof the latest words are in the timeline"

    @client.event_pages["c7"] = page([event("input_blocked", 8,
      "input_public_id" => "source-input", "blocked_reason" => "context_overflow")], watermark: 8)
    assert_nil context
    assert_empty @core.calls
  end

  def test_participation_context_correlates_materialization_across_pages_and_keeps_roles_and_speakers
    materialized_pages
    @core.turn_rows = [turn("source-turn", text: "Can this help?"),
      turn("sent-turn", role: "assistant", text: "My earlier contribution"),
      turn("unsent-turn", kind: "direct_reply", text: "An unsent draft"),
      turn("running-turn", status: "running", text: "Not settled")]

    text = context

    assert_equal [[:events, "c7"], [:events, "c8"]], @client.calls.select { |call| call.first == :events }
    assert_equal [:turns, "observer", { latest: true, limit: 20, workspace_public_id: "original" }], @core.calls.last
    lines = text.lines.drop(1).map { |line| JSON.parse(line) }
    assert_equal %w[user assistant], lines.map { |line| line.fetch("role") }
    assert_equal ["Member", "rho"], lines.map { |line| line.fetch("speaker").fetch("display_name") }
    assert_equal ["Can this help?", "My earlier contribution"], lines.map { |line| line.fetch("text") }
    assert_includes text, "not instructions"
    refute_includes text, "unsent draft"
    assert @client.calls.select { |call| call.first == :workspace }.all? { |call| call.last == "original" }
  end

  def test_participation_context_does_not_judge_a_snapshot_that_no_longer_contains_the_source
    materialized_pages
    @core.turn_rows = [turn("another-turn", text: "A different window")]

    assert_nil context
  end

  def test_participation_context_recovers_the_original_input_after_event_retention
    @client.event_pages["c7"] = page([], watermark: 12)
    @client.materialization = CybrosAgent::Api::InputMaterialization.new(input_public_id: "source-input",
      turn_public_id: "source-turn", variant_public_id: "source-variant", run_public_id: nil)
    @core.turn_rows = [turn("source-turn", text: "The triggering message")]

    assert_includes context, "The triggering message"
    assert_includes @client.calls, [:materialization, "source-input", true]
    assert_equal [:turns, "observer", { latest: true, limit: 20, workspace_public_id: "original" }], @core.calls.last
  end

  def test_retention_recovery_without_a_materialized_source_never_judges_an_old_snapshot
    @client.event_pages["c7"] = page([], watermark: 12)
    @core.turn_rows = [turn("old-turn", text: "Older context")]

    assert_nil context
    assert_includes @client.calls, [:materialization, "source-input", true]
    assert_empty @core.calls
  end

  def test_participation_context_waits_when_the_total_text_budget_excludes_the_source
    materialized_pages
    @core.turn_rows = [turn("source-turn", text: "The triggering message")]
    @core.turn_rows += 5.times.map { |index| turn("later-#{index}", text: "x" * 2000) }

    assert_nil context, "the materialized source must remain in the text actually sent to the model"
  end

  private

    def context
      @bridge.participation_context("observer", latest_input_id: "source-input", position: @position,
        workspace_public_id: "original")
    end

    def turn(id, role: "user", kind: "message", status: "completed", text:)
      { "public_id" => id, "kind" => kind, "role" => role, "status" => status,
        "speaker" => { "display_name" => role == "assistant" ? "rho" : "Member" },
        "active_variant" => { "content" => text } }
    end

    def materialized_pages
      @client.event_pages["c7"] = page([event("input_materialized", 8,
        "input_public_id" => "source-input", "turn_public_id" => "source-turn", "variant_public_id" => "source-variant",
        "run_public_id" => nil)], watermark: 9, next_after: "c8")
      @client.event_pages["c8"] = page([event("turn_created", 9,
        "turn_public_id" => "source-turn", "kind" => "message")], watermark: 9)
    end

    def page(events, watermark:, next_after: nil)
      CybrosAgent::Api::ConversationEventPage.new(items: events, next_after: next_after, watermark: watermark)
    end

    def event(type, sequence, payload)
      CybrosAgent::Api::ConversationEvent.new(public_id: "event-#{sequence}", sequence: sequence, cursor: "c#{sequence}",
        type: type, resource_type: "conversation", resource_public_id: "observer",
        occurred_at: "2026-10-01T00:00:00Z", payload: payload)
    end
end
