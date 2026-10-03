require_relative "test_helper"

class CatalogCLITest < OperatorTest
  def test_new_provider_is_saved_without_enabling_it_or_requiring_prices
    saved_session
    @transport.answer(404, { "error" => { "code" => "not_found" } })
    @transport.answer(200, catalog_configuration)

    assert_equal 0, run_cli("provider", "add", "example", "--base-url", "http://localhost:11434/v1",
      "--api-format", "openai_compatible_chat", "--credentials", "none")
    assert_equal({ "command" => { "definition" => { "api_format" => "openai_compatible_chat",
      "credentials" => "none", "base_url" => "http://localhost:11434/v1" }, "expected_lock_version" => nil } }, write.fetch(:body))
    refute output.fetch("model_provider").fetch("enabled")
    assert_equal 2, @transport.requests.length
  end

  def test_editing_a_provider_keeps_its_other_settings_and_uses_one_observed_version
    saved_session
    original = catalog_configuration
    original.fetch("configuration").fetch("definition").merge!("wire_options" => { "read_timeout" => 30 }, "concurrency_limit" => 4)
    @transport.answer(200, original)
    @transport.answer(200, original)

    assert_equal 0, run_cli("provider", "edit", "example", "--base-url", "http://localhost:1234/v1")
    definition = write.fetch(:body).dig("command", "definition")
    assert_equal "http://localhost:1234/v1", definition.fetch("base_url")
    assert_equal({ "read_timeout" => 30 }, definition.fetch("wire_options"))
    assert_equal 4, definition.fetch("concurrency_limit")
    assert_equal 3, write.fetch(:body).dig("command", "expected_lock_version")
  end

  def test_readding_a_removed_provider_uses_its_retained_version
    saved_session
    @transport.answer(200, catalog_configuration(definition: nil, source: "removed", version: 7, configured: false))
    @transport.answer(200, catalog_configuration(version: 8))
    assert_equal 0, run_cli("provider", "add", "example", "--base-url", "http://localhost:11434/v1", "--credentials", "none")
    assert_equal 7, write.fetch(:body).dig("command", "expected_lock_version")
  end

  def test_adding_a_model_without_prices_does_not_read_or_set_a_cost_unit
    saved_session
    @transport.answer(200, catalog_configuration)
    @transport.answer(200, catalog_configuration(models: [model_definition_row]))
    assert_equal 0, run_cli("model", "add", "example/vendor/chat", "--model-id", "hidden/alias",
      "--input-tokens", "32768", "--output-tokens", "8192", "--tools")
    assert_equal({ "model_id" => "hidden/alias", "capabilities" => {
      "tool_calls" => true, "limits" => { "input_tokens" => 32_768, "output_tokens" => 8192 } } },
      write.fetch(:body).dig("command", "definition"))
    assert_equal "example/vendor/chat", write.fetch(:body).dig("command", "model")
    assert_equal 2, @transport.requests.length
  end

  def test_editing_model_limits_and_clearing_prices_preserves_unedited_metadata
    saved_session
    definition = { "model_id" => "vendor/chat", "capabilities" => { "tool_calls" => true,
      "limits" => { "input_tokens" => 1000, "output_tokens" => 200 } }, "wire_options" => { "temperature" => 0.4 },
      "pricing" => { "account_unit" => "USD" } }
    @transport.answer(200, catalog_configuration(models: [model_definition_row(definition)]))
    @transport.answer(200, catalog_configuration)
    assert_equal 0, run_cli("model", "edit", "example/vendor/chat", "--input-tokens", "4000", "--no-tools", "--clear-pricing")
    result = write.fetch(:body).dig("command", "definition")
    assert_equal({ "input_tokens" => 4000, "output_tokens" => 200 }, result.dig("capabilities", "limits"))
    assert_equal false, result.dig("capabilities", "tool_calls")
    assert_equal({ "temperature" => 0.4 }, result.fetch("wire_options"))
    refute result.key?("pricing")
    assert_equal 2, @transport.requests.length
  end

  def test_explicit_prices_use_the_existing_account_unit
    saved_session
    @transport.answer(200, catalog_configuration)
    @transport.answer(200, { "account" => { "cost_unit" => "EUR" } })
    @transport.answer(200, catalog_configuration)
    assert_equal 0, run_cli("model", "add", "example/vendor/chat", "--input-price", "0.1", "--output-price", "0.3")
    assert_equal({ "account_unit" => "EUR", "schedule" => { "kind" => "catalog_only",
      "rates" => { "input_per_mtok" => "0.1", "output_per_mtok" => "0.3" } } }, write.fetch(:body).dig("command", "definition", "pricing"))
    assert_equal 1, @transport.requests.count { |row| row.fetch(:method) == :put }
  end

  def test_an_existing_model_with_null_pricing_can_receive_prices
    saved_session
    definition = { "model_id" => "vendor/chat", "pricing" => nil }
    @transport.answer(200, catalog_configuration(models: [model_definition_row(definition)]))
    @transport.answer(200, { "account" => { "cost_unit" => "EUR" } })
    @transport.answer(200, catalog_configuration)

    assert_equal 0, run_cli("model", "edit", "example/vendor/chat", "--input-price", "0.1", "--output-price", "0.3")
    assert_equal({ "account_unit" => "EUR", "schedule" => { "kind" => "catalog_only",
      "rates" => { "input_per_mtok" => "0.1", "output_per_mtok" => "0.3" } } }, write.fetch(:body).dig("command", "definition", "pricing"))
    assert_equal "vendor/chat", write.fetch(:body).dig("command", "definition", "model_id")
    assert_equal 1, @transport.requests.count { |row| row.fetch(:method) == :put }
  end

  def test_repricing_in_the_account_unit_does_not_relabel_rates_in_another_currency
    saved_session
    definition = { "pricing" => { "account_unit" => "USD", "schedule" => { "kind" => "catalog_only",
      "rates" => { "input_per_mtok" => "1", "output_per_mtok" => "3", "cached_input_per_mtok" => "0.1" } } } }
    @transport.answer(200, catalog_configuration(models: [model_definition_row(definition)]))
    @transport.answer(200, { "account" => { "cost_unit" => "EUR" } })
    @transport.answer(200, catalog_configuration)
    assert_equal 0, run_cli("model", "edit", "example/vendor/chat", "--input-price", "0.9", "--output-price", "2.7")
    assert_equal({ "input_per_mtok" => "0.9", "output_per_mtok" => "2.7" },
      write.fetch(:body).dig("command", "definition", "pricing", "schedule", "rates"))
  end

  def test_prices_require_an_explicit_unit_only_when_the_account_has_none
    saved_session
    @transport.answer(200, catalog_configuration)
    @transport.answer(200, { "account" => { "cost_unit" => nil } })
    assert_equal 2, run_cli("model", "add", "example/vendor/chat", "--input-price", "0.1", "--output-price", "0.3")
    assert_includes @error.string, "--price-unit"
    assert_empty @transport.requests.select { |row| row.fetch(:method) == :put }

    @transport.answer(200, catalog_configuration)
    @transport.answer(200, { "account" => { "cost_unit" => nil } })
    @transport.answer(200, { "account" => { "cost_unit" => "USD" } })
    @transport.answer(200, catalog_configuration)
    assert_equal 0, run_cli("model", "add", "example/vendor/chat", "--input-price", "0.1", "--output-price", "0.3", "--price-unit", "USD")
    assert_equal "USD", @transport.requests.last.fetch(:body).dig("command", "definition", "pricing", "account_unit")
  end

  def test_discovery_only_returns_directory_ids
    saved_session
    @transport.answer(200, { "models" => [{ "id" => "vendor/chat", "display_name" => nil }] })
    assert_equal 0, run_cli("provider", "discover", "example")
    assert_equal "vendor/chat", output.fetch("models").first.fetch("id")
    assert_equal "/api/v1/admin/model_providers/example/model_discovery", @transport.requests.first.fetch(:path)
    assert_nil @transport.requests.first.fetch(:body)
  end

  def test_model_removal_reset_and_provider_reset_share_the_observed_policy_version
    saved_session
    ["remove", "reset"].each do |command|
      @transport.answer(200, catalog_configuration(version: 9))
      @transport.answer(200, catalog_configuration(version: 10))
      assert_equal 0, run_cli("model", command, "example/vendor/chat")
      request = @transport.requests.last
      assert_equal 9, request.fetch(:body).dig("command", "expected_lock_version")
      assert_equal command == "remove" ? :delete : :post, request.fetch(:method)
    end
    @transport.answer(200, catalog_configuration(version: 10))
    @transport.answer(200, catalog_configuration(definition: nil, source: "removed", version: 11, configured: false))
    assert_equal 0, run_cli("provider", "reset", "example")
    assert_nil output.fetch("configuration").fetch("definition")
    assert_equal 11, output.fetch("model_provider").fetch("lock_version")
  end

  def test_a_definition_conflict_is_not_retried_and_never_prints_the_server_body
    saved_session
    @transport.answer(200, catalog_configuration)
    @transport.answer(409, { "error" => { "code" => "stale_object", "message" => "synthetic-secret" } })
    assert_equal 1, run_cli("model", "add", "example/vendor/chat", "--tools")
    assert_equal 2, @transport.requests.length
    assert_includes @error.string, "stale_object"
    refute_includes @error.string, "synthetic-secret"
  end

  private

    def write = @transport.requests.find { |row| row.fetch(:method) == :put }
end
