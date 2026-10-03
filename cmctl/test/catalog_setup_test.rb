require_relative "test_helper"

class CatalogSetupTest < OperatorTest
  class Terminal < StringIO
    def tty? = true
    def noecho = yield self
  end

  def test_an_empty_catalog_can_add_an_unpriced_provider_and_manual_model_after_discovery_failure
    sign_in_answers
    @transport.answer(200, { "model_providers" => [] })
    @transport.answer(404, { "error" => { "code" => "not_found" } })
    @transport.answer(200, catalog_configuration(version: 0))
    @transport.answer(200, { "model_provider" => catalog_configuration(version: 0).fetch("model_provider") })
    @transport.answer(200, { "model_provider" => catalog_configuration(version: 1, enabled: true).fetch("model_provider") })
    @transport.answer(200, catalog_configuration(version: 1, enabled: true))
    @transport.answer(503, nil)
    @transport.answer(200, catalog_configuration(version: 2, enabled: true, models: [model_definition_row]))
    finish_answers

    assert run_setup("", "example", "http://localhost:11434/v1", "1", "2", "Local models",
      "y", "vendor/chat", "Chat", "32768", "8192", "y", "n", "n")
    writes = @transport.requests.select { |row| row.fetch(:method) == :put }
    assert_equal %w[definition lane model_definition], writes.map { |row| row.fetch(:path).split("/").last }
    assert_equal 0, writes.fetch(1).fetch(:body).dig("command", "expected_lock_version")
    model = writes.last.fetch(:body).fetch("command")
    assert_equal 1, model.fetch("expected_lock_version")
    assert_equal "example/vendor/chat", model.fetch("model")
    assert_equal true, model.dig("definition", "capabilities", "tool_calls")
    assert_equal 32_768, model.dig("definition", "capabilities", "limits", "input_tokens")
    refute model.fetch("definition").key?("pricing")
    assert_empty @transport.requests.select { |row| row.fetch(:path).end_with?("/cost_unit") }
    assert_includes @output.string, "could not be read"
    assert_includes @output.string, "does not test inference"
    assert_includes @output.string, "Available tool-calling models: 1"
    assert_revoke_last
    refute @config.present?
  end

  def test_manual_id_remains_available_when_directory_discovery_succeeds
    existing_provider_answers
    @transport.answer(200, catalog_configuration)
    @transport.answer(200, { "models" => [{ "id" => "listed", "display_name" => "Listed model" }] })
    @transport.answer(200, catalog_configuration(models: [model_definition_row]))
    finish_answers

    assert run_setup("4", "1", "y", "2", "vendor/chat", "", "", "", "y", "n", "n")
    command = model_write.fetch(:body).fetch("command")
    assert_equal "example/vendor/chat", command.fetch("model")
    assert_equal "vendor/chat", command.dig("definition", "model_id")
    refute command.fetch("definition").key?("pricing")
    assert_includes @output.string, "Enter a model ID manually"
    assert_revoke_last
  end

  def test_edit_keeps_other_model_metadata_and_existing_prices_without_reading_the_account
    definition = { "model_id" => "upstream/alias", "display_name" => "Chat", "wire_options" => { "temperature" => 0.5 },
      "capabilities" => { "tool_calls" => true, "limits" => { "input_tokens" => 32768, "output_tokens" => 8192 } },
      "pricing" => { "account_unit" => "EUR", "schedule" => { "kind" => "catalog_only", "rates" => {
        "input_per_mtok" => "0.1", "output_per_mtok" => "0.3", "cached_input_per_mtok" => "0.01" } } } }
    existing_provider_answers
    @transport.answer(200, catalog_configuration(models: [model_definition_row(definition)]))
    @transport.answer(200, catalog_configuration)
    finish_answers

    assert run_setup("4", "1", "1", "", "", "65536", "", "", "1", "n")
    result = model_write.fetch(:body).dig("command", "definition")
    assert_equal definition.fetch("pricing"), result.fetch("pricing")
    assert_equal definition.fetch("wire_options"), result.fetch("wire_options")
    assert_equal 65_536, result.dig("capabilities", "limits", "input_tokens")
    assert_equal 8192, result.dig("capabilities", "limits", "output_tokens")
    assert_empty @transport.requests.select { |row| row.fetch(:path).end_with?("/cost_unit") }
  end

  def test_prices_are_optional_and_use_an_existing_unit_without_resetting_it
    existing_provider_answers
    @transport.answer(200, catalog_configuration)
    @transport.answer(200, { "account" => { "cost_unit" => "EUR" } })
    @transport.answer(200, catalog_configuration)
    finish_answers

    assert run_setup("4", "1", "n", "vendor/chat", "", "", "", "y", "y", "0.1", "0.3", "n")
    assert_equal "EUR", model_write.fetch(:body).dig("command", "definition", "pricing", "account_unit")
    assert_equal 1, @transport.requests.count { |row| row.fetch(:method) == :put }
    assert_includes @output.string, "EUR (kept)"
  end

  def test_editing_a_model_with_null_pricing_offers_to_add_prices
    existing_provider_answers
    definition = { "model_id" => "vendor/chat", "pricing" => nil }
    @transport.answer(200, catalog_configuration(models: [model_definition_row(definition)]))
    @transport.answer(200, { "account" => { "cost_unit" => "EUR" } })
    @transport.answer(200, catalog_configuration)
    finish_answers

    assert run_setup("4", "1", "1", "", "", "", "", "", "y", "0.1", "0.3", "n")
    assert_equal({ "account_unit" => "EUR", "schedule" => { "kind" => "catalog_only",
      "rates" => { "input_per_mtok" => "0.1", "output_per_mtok" => "0.3" } } },
      model_write.fetch(:body).dig("command", "definition", "pricing"))
    assert_includes @output.string, "Add token prices? (optional)"
    refute_includes @output.string, "Keep existing prices"
    assert_revoke_last
  end

  def test_an_explicit_price_edit_can_set_the_cost_unit_once
    existing_provider_answers
    @transport.answer(200, catalog_configuration)
    @transport.answer(200, { "account" => { "cost_unit" => nil } })
    @transport.answer(200, { "account" => { "cost_unit" => "USD" } })
    @transport.answer(200, catalog_configuration)
    finish_answers

    assert run_setup("4", "1", "n", "vendor/chat", "", "", "", "y", "y", "", "y", "0.1", "0.3", "n")
    writes = @transport.requests.select { |row| row.fetch(:method) == :put }
    assert_equal "/api/v1/admin/account/cost_unit", writes.first.fetch(:path)
    assert_equal "USD", model_write.fetch(:body).dig("command", "definition", "pricing", "account_unit")
    assert_revoke_last
  end

  def test_cancellation_after_a_provider_write_preserves_it_and_revokes_the_setup_session
    sign_in_answers
    @transport.answer(200, { "model_providers" => [] })
    @transport.answer(404, { "error" => { "code" => "not_found" } })
    definition = { "base_url" => "http://localhost:11434/v1", "api_format" => "openai_compatible_chat", "credentials" => "api_key" }
    @transport.answer(200, catalog_configuration(definition: definition, configured: false))
    @transport.answer(200, { "revoked" => true })

    assert_raises(CybrosControl::Cancelled) { run_setup("", "example", "http://localhost:11434/v1", "1", "1", "") }
    assert_equal 1, @transport.requests.count { |row| row.fetch(:method) == :put }
    assert_revoke_last
    refute_includes @output.string, "Model saved"
  end

  def test_a_concurrent_model_edit_is_not_retried_and_the_session_is_revoked
    existing_provider_answers
    @transport.answer(200, catalog_configuration(version: 7))
    @transport.answer(409, { "error" => { "code" => "stale_object" } })
    @transport.answer(200, { "revoked" => true })

    assert_raises(CybrosAgent::Api::Conflict) do
      run_setup("4", "1", "n", "vendor/chat", "", "", "", "y", "n")
    end
    assert_equal 7, model_write.fetch(:body).dig("command", "expected_lock_version")
    assert_equal 1, @transport.requests.count { |row| row.fetch(:path).end_with?("/model_definition") }
    assert_revoke_last
    refute_includes @output.string, "Model saved"
  end

  private

    def run_setup(*answers)
      @output = Terminal.new
      @error = StringIO.new
      input = Terminal.new((["owner@example.test", "synthetic-password"] + answers).join("\n") + "\n")
      CybrosControl::Setup.new(url: "http://localhost:3000", input: input, output: @output, error: @error,
        sessions: ->(url) { CybrosAgent::Sessions.new(base_url: url, transport: @transport) },
        clients: ->(url, token) { CybrosAgent::PlatformClient.new(base_url: url, credential: token, transport: @transport) }).run
    end

    def sign_in_answers
      @transport.answer(201, { "token" => TOKEN, "token_type" => "Bearer", "session" => SESSION })
      @transport.answer(200, profile)
    end

    def existing_provider_answers
      sign_in_answers
      @transport.answer(200, { "model_providers" => [lane(version: 3, enabled: true)] })
    end

    def finish_answers
      @transport.answer(200, { "models" => [{ "ref" => "example/vendor/chat", "provider" => "example", "workload" => "text_generation",
        "available" => true, "visible" => true, "capabilities" => { "tool_calls" => true }, "pricing" => { "state" => "cost_unknown" } }] })
      @transport.answer(200, { "revoked" => true })
    end

    def model_write = @transport.requests.find { |row| row.fetch(:method) == :put && row.fetch(:path).end_with?("/model_definition") }

    def assert_revoke_last
      assert_equal :delete, @transport.requests.last.fetch(:method)
      assert_equal "/api/v1/session", @transport.requests.last.fetch(:path)
    end
end
