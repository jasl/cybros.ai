require "test_helper"
require "rho/agent_presets"
require_relative "support/environment_fixtures"

class AgentPresetMemoryTest < Minitest::Test
  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
    @catalog = Rho::AgentPresets.new(store: -> { @store })
  end

  def test_nullable_empty_and_natural_root_limits_are_saved_without_widening
    roots = %w[conversation workspace user agent speaker].map { |scope| binding(scope) }
    assert_nil @catalog.fetch(create(nil).public_id).configuration.fetch("memory_context_limit")
    [{ "bindings" => [] }, { "bindings" => roots }].each do |limit|
      entry = create(limit)
      assert_equal limit, @catalog.fetch(entry.public_id).configuration.fetch("memory_context_limit")
    end
  end

  def test_invalid_shape_is_refused_before_the_preset_store_is_written
    invalid = [
      {}, { "bindings" => nil }, { "bindings" => "conversation" }, { "bindings" => [nil] },
      { "bindings" => [binding("conversation")] * 17 },
      { "bindings" => [binding("conversation", "write")] },
      { "bindings" => [binding("conversation").except("access")] },
      { "bindings" => [binding("conversation").merge("conversation_public_id" => "other-room")] },
      { "bindings" => [binding("conversation"), binding("speaker").merge("speaker_public_id" => "person")] },
      { "bindings" => [binding("conversation"), binding("other")] },
      { "bindings" => [binding("conversation").merge("source" => { "collection_public_id" => "private-collection" })] },
      { "bindings" => [binding("conversation"), binding("speaker").merge("source" => { "scope" => "speaker", "speaker_public_id" => "private-subject" })] },
      { "bindings" => [binding("conversation").merge("capture" => { "collection_public_id" => "private-collection" })] },
    ]
    invalid.each do |limit|
      error = assert_raises(Rho::AgentPresets::Error) { create(limit) }
      assert_includes error.message, "memory_context_limit"
      assert_empty @store.rows
    end
  end

  def test_aliases_duplicates_and_a_nonempty_limit_without_conversation_are_refused
    invalid = [
      { "bindings" => [binding("conversation"), binding("workspace").merge("name" => "shared")] },
      { "bindings" => [binding("conversation"), binding("workspace").merge("name" => "agent")] },
      { "bindings" => [binding("conversation"), binding("conversation", "read_write")] },
      { "bindings" => [binding("workspace")] },
    ]
    invalid.each do |limit|
      error = assert_raises(Rho::AgentPresets::Error) { create(limit) }
      assert_includes error.message, "memory_context_limit"
      assert_empty @store.rows
    end
  end

  def test_invalid_replacement_retains_the_saved_limit
    limit = { "bindings" => [] }
    entry = create(limit)
    assert_raises(Rho::AgentPresets::Error) do
      @catalog.replace(entry.public_id, name: entry.name, description: entry.description,
        configuration: { "memory_context_limit" => { "bindings" => [binding("agent")] } })
    end
    assert_equal limit, @catalog.fetch(entry.public_id).configuration.fetch("memory_context_limit")
  end

  private

    def create(limit)
      @catalog.create(name: "Limited", description: "Authored memory limit", configuration: { "memory_context_limit" => limit })
    end

    def binding(scope, access = "read") = { "name" => scope, "source" => { "scope" => scope }, "access" => access }
end
