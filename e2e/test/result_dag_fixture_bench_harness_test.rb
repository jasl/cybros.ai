$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "tmpdir"
require "support/result_dag"
require "support/catalog_overlay"
require "support/fixtures/result_dag/work"

class ResultDagFixtureBenchHarnessTest < Minitest::Test
  def test_listing_and_inspection_use_the_generated_data
    Dir.mktmpdir do |root|
      data = E2E::ResultDag.prepare(root, "dynamic")
      work = ResultDagWork.new(root)
      listing = work.call(["list"])
      assert_equal data.fetch("records").map { |record| record.fetch("path") }, listing.fetch("files")
      assert_equal data.fetch("noise"), listing.fetch("noise")
      results = listing.fetch("files").select { |path| path.end_with?(".rb") }.map do |path|
        work.call(["inspect", path]).slice("path", "score")
      end
      assert_equal E2E::ResultDag.expected("dynamic", data),
        { "items" => results.sort_by { |item| item.fetch("path") }, "total" => results.sum { |item| item.fetch("score") } }
      assert_raises(RuntimeError) { work.call(["inspect", "invented.rb"]) }
    end
  end

  def test_only_a_valid_c_consumption_releases_source_b
    Dir.mktmpdir do |root|
      E2E::ResultDag.prepare(root, "dependencies")
      work = ResultDagWork.new(root)
      b = Thread.new { work.call(%w[source b]) }
      a = work.call(%w[source a])
      assert_raises(RuntimeError) { work.call(%w[consume c fabricated-token]) }
      assert_nil b.join(0.05), "B should still be waiting for C"
      assert_equal 7, work.call(["consume", "c", a.fetch("token")]).fetch("value")
      refute_nil b.join(2), "C did not release B"
      assert_equal 18, work.call(["consume", "d", a.fetch("token"), b.value.fetch("token")]).fetch("value")
    ensure
      b&.kill
      b&.join
    end
  end

  def test_the_second_discovery_waits_for_the_first_groups_inspection
    Dir.mktmpdir do |root|
      E2E::ResultDag.prepare(root, "pipeline")
      work = ResultDagWork.new(root)
      b = Thread.new { work.call(%w[discover b]) }
      a = work.call(%w[discover a])
      assert_nil b.join(0.05), "B must expose a global discovery barrier"
      path = a.fetch("files").find { |file| file.end_with?(".rb") }
      work.call(["inspect", path])
      refute_nil b.join(2), "A's inspection did not release B"
      assert b.value.fetch("files").all? { |file| file.start_with?("b-") }
    ensure
      b&.kill
      b&.join
    end
  end

  def test_successful_empty_listing_and_failed_listing_are_distinct
    Dir.mktmpdir do |root|
      data = E2E::ResultDag.prepare(root, "empty")
      assert_equal [], ResultDagWork.new(root).call(["list"]).fetch("files")
      assert_equal({ "items" => [], "total" => 0 }, E2E::ResultDag.expected("empty", data))

      E2E::ResultDag.prepare(root, "failure")
      error = assert_raises(RuntimeError) { ResultDagWork.new(root).call(["list"]) }
      assert_equal "listing_unavailable", error.message
      events = File.readlines(File.join(root, "events.jsonl")).map { |line| JSON.parse(line) }
      assert_equal "failed", events.last.fetch("state")
      refute events.any? { |event| event.fetch("operation") == "inspect" }
    end
  end

  def test_preflight_refuses_missing_opt_in_keys_and_unknown_cases_without_io
    assert_raises(ArgumentError) { E2E::ResultDag.validate!({}) }
    env = { "E2E_LIVE" => "1", "RAILS_ENV" => "development",
            "E2E_LIVE_MODEL" => "openrouter/acme/test-model", "OPENROUTER_API_KEY" => "fixture-value" }
    assert_equal E2E::ResultDag::CASES, E2E::ResultDag.validate!(env)
    assert_raises(ArgumentError) { E2E::ResultDag.validate!(env.merge("E2E_LIVE_MODEL" => "unknown/test-model")) }
    assert_raises(ArgumentError) { E2E::ResultDag.validate!(env.merge("CI" => "true")) }
    assert_raises(ArgumentError) { E2E::ResultDag.validate!(env.merge("OPENROUTER_API_KEY" => "")) }
    assert_raises(ArgumentError) { E2E::ResultDag.validate!(env.merge("E2E_RESULT_DAG_ONLY" => "typo")) }
    assert_raises(ArgumentError) { E2E::ResultDag.validate!(env.merge("E2E_RESULT_DAG_EFFORT" => "low")) }
    assert_raises(ArgumentError) { E2E::ResultDag.validate!(env.merge("E2E_RESULT_DAG_PIPELINE_CORRECTION" => "1")) }
    assert_equal ["pipeline"], E2E::ResultDag.validate!(env.merge("E2E_RESULT_DAG_PIPELINE_CORRECTION" => "1",
      "E2E_RESULT_DAG_ONLY" => "pipeline"))
  end

  def test_the_default_overlay_keeps_the_existing_catalog_and_adds_isolated_journey_lanes
    root = File.expand_path("../../nexus", __dir__)
    expected = YAML.safe_load_file(File.join(root, E2E::CatalogOverlay::SOURCE))
    expected.fetch("providers").fetch("dev")["base_url"] = "http://127.0.0.1:12345"
    overlay = E2E::CatalogOverlay.new(nexus_root: root, provider_base_url: "http://127.0.0.1:12345").install
    actual = YAML.safe_load_file(overlay.path)
    assert_equal expected.fetch("providers"), actual.fetch("providers").except("e2e-key")
    assert_equal expected.fetch("models"), actual.fetch("models").except("e2e-key/mock-keyed-text",
      E2E::CatalogOverlay::WEB_FETCH_MODEL, E2E::CatalogOverlay::ATTACHMENTS_MODEL,
      E2E::CatalogOverlay::DOCUMENT_MODEL, E2E::CatalogOverlay::PROMPT_FORMAT_MODEL,
      E2E::CatalogOverlay::REASONING_SWITCH_MODEL)
    assert_equal "http://127.0.0.1:12345", actual.dig("providers", "e2e-key", "base_url")
    assert_equal "api_key", actual.dig("providers", "e2e-key", "credentials")
    assert_equal expected.dig("models", "dev/mock-text"), actual.dig("models", "e2e-key/mock-keyed-text")
    web_fetch = actual.fetch("models").fetch(E2E::CatalogOverlay::WEB_FETCH_MODEL)
    assert_equal "mock-text", web_fetch.delete("model_id")
    assert_equal 32_768, web_fetch.fetch("capabilities").fetch("limits").fetch("input_tokens")
    web_fetch.fetch("capabilities").fetch("limits")["input_tokens"] = 8192
    assert_equal expected.dig("models", "dev/mock-text"), web_fetch
    attachments = actual.fetch("models").fetch(E2E::CatalogOverlay::ATTACHMENTS_MODEL)
    assert_equal "mock-text", attachments.delete("model_id")
    assert_equal 12_288, attachments.fetch("capabilities").fetch("limits").fetch("input_tokens")
    attachments.fetch("capabilities").fetch("limits")["input_tokens"] = 8192
    assert_equal expected.dig("models", "dev/mock-text"), attachments
    document = actual.fetch("models").fetch(E2E::CatalogOverlay::DOCUMENT_MODEL)
    assert_equal "mock-text", document.delete("model_id")
    assert_equal %w[image file], document.fetch("capabilities").fetch("input_modalities")
    assert_equal 12_288, document.fetch("capabilities").fetch("limits").fetch("input_tokens")
    document.fetch("capabilities")["input_modalities"] = ["image"]
    document.fetch("capabilities").fetch("limits")["input_tokens"] = 8192
    assert_equal expected.dig("models", "dev/mock-text"), document
    prompt_format = actual.fetch("models").fetch(E2E::CatalogOverlay::PROMPT_FORMAT_MODEL)
    assert_equal "mock-text", prompt_format.delete("model_id")
    assert_equal({ "prompt_format" => "qwen3_5" }, prompt_format.delete("wire_options"))
    assert_equal expected.dig("models", "dev/mock-text"), prompt_format
    reasoning_switch = actual.fetch("models").fetch(E2E::CatalogOverlay::REASONING_SWITCH_MODEL)
    assert_equal "mock-text", reasoning_switch.delete("model_id")
    assert_equal true, reasoning_switch.fetch("capabilities").fetch("reasoning").delete("disable_supported")
    assert_equal expected.dig("models", "dev/mock-text"), reasoning_switch
    assert_equal 8192, actual.dig("models", "dev/mock-text", "capabilities", "limits", "input_tokens")
    assert_empty E2E::ResultDag.model_overrides(nexus_root: root, env: {})
  ensure
    overlay&.release
  end

  def test_glm_flash_low_effort_changes_only_the_selected_worlds_model_default
    root = File.expand_path("../../nexus", __dir__)
    model = "openrouter/z-ai/glm-5.3-flash"
    env = { "E2E_LIVE_MODEL" => model, "E2E_RESULT_DAG_EFFORT" => "low" }
    original = YAML.safe_load_file(File.join(root, "config/model_catalog/50_openrouter.yml")).fetch("models").fetch(model)
    overrides = E2E::ResultDag.model_overrides(nexus_root: root, env: env)
    overlay = E2E::CatalogOverlay.new(nexus_root: root, provider_base_url: "http://127.0.0.1:12345",
      model_overrides: overrides).install
    actual = YAML.safe_load_file(overlay.path).fetch("models").fetch(model)
    expected = JSON.parse(JSON.generate(original))
    expected.fetch("capabilities").fetch("reasoning")["default_effort"] = "low"
    assert_equal "low", actual.fetch("capabilities").fetch("reasoning").fetch("default_effort")
    assert_equal expected, actual
    assert_equal original, YAML.safe_load_file(File.join(root, "config/model_catalog/50_openrouter.yml")).fetch("models").fetch(model)
  ensure
    overlay&.release
  end
end
