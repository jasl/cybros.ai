require "test_helper"

class PlatformModelConfigurationTest < Minitest::Test
  LANE = {
    "id" => "custom", "credentials" => "none", "enabled" => false,
    "lock_version" => 2, "configured" => true, "models" => 1, "unavailable_until" => nil,
  }.freeze
  DEFINITION = { "api_format" => "openai_compatible_chat", "base_url" => "http://localhost:11434/v1", "credentials" => "none" }.freeze

  def test_configuration_keeps_provider_and_model_metadata_on_the_admin_surface
    body = configuration
    value = provider([[200, {}, body]]).configuration

    assert_equal "/api/v1/admin/model_providers/custom", request.fetch(:path)
    assert_equal 2, value.provider.lock_version
    assert_equal DEFINITION, value.definition
    assert_equal "custom", value.source
    model = value.models.fetch(0)
    assert_equal "custom/vendor/chat", model.model
    assert_equal({ "capabilities" => { "tool_calls" => true } }, model.definition)
    refute model.removed
    body.fetch("configuration").fetch("definition")["base_url"] = "elsewhere"
    assert_equal "http://localhost:11434/v1", value.definition.fetch("base_url")
  end

  def test_definition_creation_and_reset_carry_the_observed_version_without_exposing_credentials
    removed_body = configuration(definition: nil, source: "removed")
    removed_body["model_provider"] = LANE.merge("credentials" => nil, "configured" => false)
    context = provider([[200, {}, configuration], [200, {}, removed_body]])
    saved = context.set_definition(definition: DEFINITION, expected_lock_version: nil)
    removed = context.reset_definition(expected_lock_version: saved.provider.lock_version)

    assert_equal [:put, :delete], @transport.requests.map { |row| row.fetch(:method) }
    assert_equal ["/api/v1/admin/model_providers/custom/definition"] * 2, @transport.requests.map { |row| row.fetch(:path) }
    assert_equal({ "command" => { "definition" => DEFINITION, "expected_lock_version" => nil } }, request.fetch(:body))
    assert_equal({ "command" => { "expected_lock_version" => 2 } }, @transport.requests.last.fetch(:body))
    assert_nil removed.definition
    assert_equal "removed", removed.source
    assert_nil removed.provider.credentials
    assert_equal 2, removed.provider.lock_version
    refute_includes saved.members, :api_key
  end

  def test_model_definition_put_remove_and_reset_use_the_full_model_reference
    context = provider(Array.new(3) { [200, {}, configuration] })
    definition = { "model_id" => "vendor/chat", "capabilities" => { "limits" => { "input_tokens" => 32_768 } } }
    context.set_model_definition(model: "custom/vendor/chat", definition: definition, expected_lock_version: 2)
    context.remove_model_definition(model: "custom/vendor/chat", expected_lock_version: 3)
    context.reset_model_definition(model: "custom/vendor/chat", expected_lock_version: 4)

    assert_equal [:put, :delete, :post], @transport.requests.map { |row| row.fetch(:method) }
    assert_equal ["model_definition", "model_definition", "model_definition/reset"],
      @transport.requests.map { |row| row.fetch(:path).delete_prefix("/api/v1/admin/model_providers/custom/") }
    assert_equal [2, 3, 4], @transport.requests.map { |row| row.fetch(:body).dig("command", "expected_lock_version") }
    assert @transport.requests.all? { |row| row.fetch(:body).dig("command", "model") == "custom/vendor/chat" }
    assert_equal definition, request.fetch(:body).dig("command", "definition")
  end

  def test_tombstones_are_visible_to_the_administrator
    body = configuration
    body.fetch("configuration")["models"] = [{ "model" => "custom/vendor/chat", "definition" => nil, "source" => "override", "removed" => true }]
    model = provider([[200, {}, body]]).configuration.models.fetch(0)
    assert model.removed
    assert_nil model.definition
  end

  def test_discovery_is_one_bodyless_post_and_keeps_upstream_ids_unchanged
    context = provider([[200, {}, { "models" => [{ "id" => "vendor/chat", "display_name" => nil }] }]])
    assert_equal "vendor/chat", context.discover_models.fetch(0).id
    assert_equal :post, request.fetch(:method)
    assert_equal "/api/v1/admin/model_providers/custom/model_discovery", request.fetch(:path)
    assert_nil request.fetch(:body)
  end

  def test_invalid_success_and_conflicts_are_not_hidden_or_retried
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      provider([[200, {}, { "model_provider" => LANE }]]).configuration
    end
    context = provider([[409, {}, { "error" => { "code" => "stale_object" } }]])
    error = assert_raises(CybrosAgent::Api::Conflict) do
      context.set_definition(definition: DEFINITION, expected_lock_version: 1)
    end
    assert_equal "stale_object", error.code
    assert_equal 1, @transport.requests.length
  end

  private

    def provider(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      CybrosAgent::PlatformClient.new(base_url: "http://example.test", credential: "human-session",
        transport: @transport).model_providers.provider("custom")
    end

    def request = @transport.requests.fetch(0)

    def configuration(definition: DEFINITION.dup, source: "custom")
      { "model_provider" => LANE, "configuration" => { "definition" => definition, "source" => source,
        "models" => [{ "model" => "custom/vendor/chat", "definition" => { "capabilities" => { "tool_calls" => true } },
          "source" => "override", "removed" => false }] } }
    end
end
