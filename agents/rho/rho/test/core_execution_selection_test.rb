require "test_helper"

class CoreExecutionSelectionTest < Minitest::Test
  include RhoTest::CliHarness

  def intent
    { "source" => "explicit", "model" => "chosen/task", "constraint" => "provider", "alternatives" => ["chosen/alternate"] }
  end

  def test_regeneration_keeps_optional_selection_and_empty_fallbacks
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/regenerate" => Array.new(2) { [200, { "regenerate" => {} }] }))

    core.regenerate("child", "turn", idempotency_key: "plain")
    plain = posted(seen)
    refute plain.key?("model_selection")
    refute plain.key?("fallback_models")

    core.regenerate("child", "turn", idempotency_key: "selected", model: "chosen/task", model_selection: intent, fallback_models: [])
    selected = posted(seen)
    assert_equal intent, selected.fetch("model_selection")
    assert_empty selected.fetch("fallback_models")
  end

  def test_schedules_preserve_optional_selection_and_explicit_recovery_clears
    seen = []
    row = { "public_id" => "job", "lock_version" => 0 }
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /conversations/schedules/create" => [[201, { "schedule" => row }]],
      "POST /conversations/schedules/update" => Array.new(3) { [200, { "schedule" => row }] }))

    core.create_schedule("child", prompt: "Continue", rule: { "kind" => "once", "run_at" => "2026-10-13T09:00:00Z" },
      idempotency_key: "selected", model_selection: intent, fallback_models: [])
    assert_equal intent, posted(seen).fetch("model_selection")
    assert_empty posted(seen).fetch("fallback_models")

    core.update_schedule("child", "job", expected_lock_version: 0, name: "Renamed")
    refute posted(seen).key?("model_selection")
    refute posted(seen).key?("fallback_models")

    core.update_schedule("child", "job", expected_lock_version: 0, fallback_models: [])
    assert_empty posted(seen).fetch("fallback_models")
    core.update_schedule("child", "job", expected_lock_version: 0, model_selection: nil, fallback_models: nil)
    assert_nil posted(seen).fetch("model_selection")
    assert_nil posted(seen).fetch("fallback_models")
  end

  private

    def posted(seen)
      JSON.parse(seen.grep(/\APOST /).last.partition("\r\n\r\n").last)
    end
end
