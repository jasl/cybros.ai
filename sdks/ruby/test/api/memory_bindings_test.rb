require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiMemoryBindingsTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_create_preserves_default_disabled_and_named_memory_contexts
    conversations([[201, {}, contract.fetch("valid_fixture")]]).create(idempotency_key: "default")
    refute request.dig(:body, "conversation").key?("memory_context")

    conversations([[201, {}, contract.fetch("valid_fixture")]])
      .create(idempotency_key: "explicit-default", memory_context: nil)
    assert request.dig(:body, "conversation").key?("memory_context")
    assert_nil request.dig(:body, "conversation", "memory_context")

    [{ "bindings" => [] }, bindings].each do |configuration|
      created = conversations([[201, {}, conversation_body(configuration)]])
        .create(idempotency_key: "configured", memory_context: configuration)

      assert_equal configuration, request.dig(:body, "conversation", "memory_context")
      assert_equal configuration, created.conversation.memory_context
    end
  end

  def test_set_memory_context_posts_the_whole_configuration_and_reads_it_back
    conversation = chat([[200, {}, conversation_body(bindings)]]).set_memory_context(memory_context: bindings)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/memory_context", request.fetch(:path)
    assert_equal({ "memory_context" => bindings }, request.fetch(:body))
    assert_equal bindings, conversation.memory_context
    assert_predicate conversation.memory_context, :frozen?
    assert_predicate conversation.memory_context.fetch("bindings"), :frozen?
  end

  def test_set_memory_context_distinguishes_disabling_memory_from_resetting_defaults
    disabled = { "bindings" => [] }
    conversation = chat([[200, {}, conversation_body(disabled)]]).set_memory_context(memory_context: disabled)
    assert_equal disabled, request.dig(:body, "memory_context")
    assert_equal disabled, conversation.memory_context

    conversation = chat([[200, {}, conversation_body(nil)]]).set_memory_context(memory_context: nil)
    assert_equal({ "memory_context" => nil }, request.fetch(:body))
    assert_nil conversation.memory_context
  end

  def test_variant_default_memory_context_survives_serialization_as_null
    body = contract.fetch("valid_variant_fixture")
    variant = chat([[200, {}, body]]).turns.edit(TURN_ID, text: "corrected")

    assert_nil body.fetch("variant").fetch("memory_context")
    assert_nil variant.memory_context
    assert_nil variant.to_h.fetch(:memory_context)
    refute variant.to_h.key?(:attachments), "other optional fields retain their existing omission behavior"
  end

  def test_variant_memory_context_keeps_explicit_off_and_named_bindings
    %w[disabled_memory_variant_fixture bound_memory_variant_fixture].each do |fixture|
      body = contract.fetch(fixture)
      configuration = body.fetch("variant").fetch("memory_context")
      variant = chat([[200, {}, body]]).turns.edit(TURN_ID, text: "corrected")

      assert_equal configuration, variant.memory_context
      assert_equal configuration, variant.to_h.fetch(:memory_context)
      assert_predicate variant.memory_context, :frozen?
      assert_predicate variant.memory_context.fetch("bindings"), :frozen?
    end

    assert_includes contract.fetch("variant_projection_required"), "memory_context"
    assert_equal [], contract.dig("disabled_memory_variant_fixture", "variant", "memory_context", "bindings")
    refute_empty contract.dig("bound_memory_variant_fixture", "variant", "memory_context", "bindings")
  end

  def test_grep_sends_search_options_and_keeps_binding_paths_in_matches
    matches = [{ "path" => "group/notes.md", "line_number" => 2, "text" => "The plan" }]
    result = chat([[200, {}, { "matches" => matches, "truncated" => true }]]).memory
      .grep(pattern: "plan", path: "group/", ignore_case: true, limit: 1)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/memory/grep", request.fetch(:path)
    assert_equal({ "memory" => { "pattern" => "plan", "path" => "group/", "ignore_case" => true, "limit" => 1 } },
      request.fetch(:body))
    assert_equal matches, result.fetch("matches")
    assert result.fetch("truncated")

    result = chat([[200, {}, { "matches" => [], "truncated" => false }]]).memory.grep(pattern: "absent")
    assert_equal({ "memory" => { "pattern" => "absent", "ignore_case" => false } }, request.fetch(:body))
    assert_empty result.fetch("matches")
    refute result.fetch("truncated")
  end

  def test_edit_sends_exact_text_and_the_observed_version_without_a_prior_read
    document = CybrosAgentTest::ContractFixtures.pack("memory_documents.json").fetch("valid_fixture").fetch("memory")
    result = chat([[200, {}, { "memory" => document.merge("path" => "group/notes.md", "content" => "new plan") }]])
      .memory.edit(path: "group/notes.md", old_text: "old plan", new_text: "new plan",
        expected_public_id: document.fetch("public_id"), expected_lock_version: 1)

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/memory/edit", request.fetch(:path)
    assert_equal({ "memory" => { "path" => "group/notes.md", "old_text" => "old plan", "new_text" => "new plan",
                                "expected_public_id" => document.fetch("public_id"), "expected_lock_version" => 1 } },
      request.fetch(:body))
    assert_equal 1, @transport.requests.length
    assert_equal "group/notes.md", result.path
    assert_equal "new plan", result.content
  end

  def test_edit_relays_a_stale_version_without_reading_or_retrying
    error = assert_raises(CybrosAgent::Api::Conflict) do
      chat([[409, {}, { "error" => { "code" => "stale_object", "message" => "Read the current document." } }]])
        .memory.edit(path: "group/notes.md", old_text: "old", new_text: "new",
          expected_public_id: "019f0000-0000-7000-8000-000000000700", expected_lock_version: 1)
    end
    assert_equal "stale_object", error.code
    assert_equal 1, @transport.requests.length
  end

  private

    def bindings
      { "bindings" => [
        { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
        { "name" => "group", "scope" => "conversation", "access" => "read",
          "conversation_public_id" => "019f0000-0000-7000-8000-000000000701" },
      ] }
    end

    def conversation_body(configuration)
      { "conversation" => contract.fetch("valid_fixture").fetch("conversation").merge("memory_context" => configuration) }
    end
end
