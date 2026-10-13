require "test_helper"
require "rho/agent_presets"
require_relative "support/environment_fixtures"

class AgentPresetsTest < Minitest::Test
  Profile = Data.define(:store) do
    def store_entries = store
    def agents = raise "Preset operations must not create or edit Agent Users"
  end

  def setup
    @store = RhoTest::EnvironmentFixtures::FakeStore.new
    @profile = Profile.new(store: @store)
    @catalog = catalog
  end

  def test_initial_catalog_has_editable_presets_and_roles_without_user_creation
    entries = @catalog.list

    assert_equal %w[Probius Adjutant worker planner explorer reviewer], entries.map(&:name)
    assert_equal 6, entries.map(&:public_id).uniq.length
    entries.each { |entry| assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, entry.public_id) }
    assert_equal entries[0].public_id, @catalog.main_preset_public_id
    assert_equal entries[1].public_id, @catalog.default_bot_preset_public_id
    assert_nil entries[0].role
    assert_nil entries[1].role
    assert_equal %w[worker planner explorer reviewer], entries.filter_map { |entry| entry.role&.name }
    entries.drop(2).each do |entry|
      assert_equal "follow", entry.configuration.fetch("model_mode")
      refute_empty entry.role.description
      refute_empty entry.configuration.fetch("system_prompt")
    end
    assert_equal 1, @store.rows.length
    assert_equal ["rho.presets", "catalog"], [@store.rows.first.namespace, @store.rows.first.key]
    assert_equal 1, writes.length
    @catalog.list
    assert_equal 1, writes.length, "reading an initialized catalog does not rewrite its seeds"
  end

  def test_edits_selection_and_deleted_seeds_survive_reopening
    main = @catalog.fetch(@catalog.main_preset_public_id)
    worker = @catalog.list.find { |entry| entry.role&.name == "worker" }
    explorer = @catalog.list.find { |entry| entry.role&.name == "explorer" }
    @catalog.replace(main.public_id, name: "My coworker", description: "Saved choice",
      configuration: { "system_prompt" => "Remember this edit", "fallback_models" => [] })
    @catalog.publish(worker.public_id, name: "builder", description: "Build the requested change")
    @catalog.remove(explorer.public_id)
    @catalog.select_default_bot(main.public_id)

    reopened = catalog
    assert_equal main.public_id, reopened.main_preset_public_id
    assert_equal main.public_id, reopened.default_bot_preset_public_id
    assert_equal "My coworker", reopened.fetch(main.public_id).name
    assert_equal "Remember this edit", reopened.fetch(main.public_id).configuration.fetch("system_prompt")
    assert_equal "builder", reopened.fetch(worker.public_id).role.name
    assert_equal 5, reopened.list.length
    assert_raises(Rho::AgentPresets::Error) { reopened.fetch(explorer.public_id) }
  end

  def test_competing_initial_reads_use_the_same_committed_preset_identities
    winner = catalog
    winning_entries = nil
    create = @store.method(:create)
    @store.define_singleton_method(:create) do |**fields|
      unless winning_entries
        winning_entries = []
        winning_entries = winner.list
      end
      create.call(**fields)
    end

    entries = @catalog.list

    assert_equal winning_entries, entries
    assert_equal winner.main_preset_public_id, @catalog.main_preset_public_id
    assert_equal winner.default_bot_preset_public_id, @catalog.default_bot_preset_public_id
    assert_equal 1, @store.rows.length
    assert_equal 2, writes.count { |call| call.first == :create }
    assert_equal 0, writes.count { |call| call.first == :update }
    assert_equal entries, catalog.list
  end

  def test_prompt_text_preserves_whitespace_and_counts_utf8_bytes_with_shared_guidance
    text = "  Use 中文.\n\n    Keep this indentation.\n"
    entry = @catalog.create(name: "Literal", description: "Preserve authored text", configuration: { "system_prompt" => text })
    assert_equal text, entry.configuration.fetch("system_prompt")
    available = Rho::AgentPresets::MAX_PROMPT_BYTES - Rho::RunDeclaration::GUIDELINE.bytesize - 2
    fitting = "界" * (available / 3) + "x" * (available % 3)
    @catalog.replace(entry.public_id, name: "Literal", description: "Maximum size", configuration: { "system_prompt" => fitting })
    assert_equal fitting, @catalog.fetch(entry.public_id).configuration.fetch("system_prompt")
    error = assert_raises(Rho::AgentPresets::Error) do
      @catalog.replace(entry.public_id, name: "Literal", description: "Too large", configuration: { "system_prompt" => fitting + "x" })
    end
    assert_match(/at most 64 KiB of UTF-8 text/, error.message)
    assert_equal fitting, @catalog.fetch(entry.public_id).configuration.fetch("system_prompt")
    [1, false, [], {}].each do |value|
      assert_raises(Rho::AgentPresets::Error) { @catalog.create(name: "Invalid", description: "Wrong type", configuration: { "system_prompt" => value }) }
    end
  end

  def test_default_choices_change_together_or_keep_the_previous_selection
    initial = @catalog.main_preset_public_id
    replacement = @catalog.default_bot_preset_public_id
    assert_raises(Rho::AgentPresets::Error) do
      @catalog.select_defaults("main_preset_public_id" => replacement, "default_bot_preset_public_id" => "missing")
    end
    assert_equal initial, catalog.main_preset_public_id
    @catalog.select_defaults("main_preset_public_id" => replacement, "default_bot_preset_public_id" => initial)
    assert_equal replacement, catalog.main_preset_public_id
    assert_equal initial, catalog.default_bot_preset_public_id
  end

  def test_shared_references_read_one_configuration_and_old_reads_do_not_change
    preset = @catalog.create(name: "Shared", description: "Reusable configuration",
      configuration: { "system_prompt" => "Before", "tools" => ["memory_read"],
                       "prompt_template" => { "blocks" => [{ "type" => "history" }] } })
    consumer_a = { identity: "main-a", preset_public_id: preset.public_id }
    consumer_b = { identity: "bot-b", preset_public_id: preset.public_id }
    captured = @catalog.fetch(consumer_a.fetch(:preset_public_id))
    @catalog.replace(preset.public_id, name: "Shared", description: "Reusable configuration",
      configuration: { "system_prompt" => "After", "tools" => [] })

    assert_equal "Before", captured.configuration.fetch("system_prompt")
    assert_equal ["memory_read"], captured.configuration.fetch("tools")
    assert_equal "After", @catalog.fetch(consumer_a.fetch(:preset_public_id)).configuration.fetch("system_prompt")
    assert_equal "After", @catalog.fetch(consumer_b.fetch(:preset_public_id)).configuration.fetch("system_prompt")
    refute_equal consumer_a.fetch(:identity), consumer_b.fetch(:identity)
    refute @store.rows.first.value.to_s.include?(consumer_a.fetch(:identity))
    refute @store.rows.first.value.to_s.include?(consumer_b.fetch(:identity))

    captured.configuration.fetch("prompt_template").fetch("blocks").clear
    assert_equal [], @catalog.fetch(preset.public_id).configuration.fetch("tools")
  end

  def test_duplicate_copies_configuration_without_publication_or_default_references
    source = @catalog.create(name: "Custom source", description: "Nested authoring data",
      configuration: { "system_prompt" => "Keep the source", "prompt_template" => { "blocks" => [{ "type" => "history" }] } })
    @catalog.publish(source.public_id, name: "custom_worker", description: "Choose this custom policy")
    duplicate = @catalog.duplicate(source.public_id, name: "Custom worker")

    refute_equal source.public_id, duplicate.public_id
    assert_equal source.configuration, duplicate.configuration
    assert_nil duplicate.role
    refute_equal duplicate.public_id, @catalog.main_preset_public_id
    refute_equal duplicate.public_id, @catalog.default_bot_preset_public_id
    duplicate.configuration.fetch("prompt_template").fetch("blocks").clear
    assert_equal [{ "type" => "history" }], @catalog.fetch(source.public_id).configuration.dig("prompt_template", "blocks")
    assert_equal [{ "type" => "history" }], @catalog.fetch(duplicate.public_id).configuration.dig("prompt_template", "blocks")
    @catalog.replace(duplicate.public_id, name: duplicate.name, description: duplicate.description,
      configuration: { "system_prompt" => "A different task policy", "fallback_models" => [] })
    assert_equal source.configuration, @catalog.fetch(source.public_id).configuration
    @catalog.fetch(source.public_id).configuration["system_prompt"] = "Uncommitted mutation"
    assert_equal source.configuration, @catalog.fetch(source.public_id).configuration
  end

  def test_fallback_and_tool_selection_preserve_inheritance_and_explicit_empty_lists
    inherited = @catalog.create(name: "Inherited", description: "Use instance defaults")
    disabled = @catalog.create(name: "Disabled", description: "No automatic fallback or tools",
      configuration: { "fallback_models" => [], "tools" => [], "runner_tool_names" => [] })
    ordered = @catalog.create(name: "Ordered", description: "Use this order",
      configuration: { "model" => "provider-a/primary", "fallback_models" => [" provider-b/second ", "provider-c/third", "provider-b/second"] })

    assert_nil inherited.configuration.fetch("fallback_models")
    assert_nil inherited.configuration.fetch("tools")
    assert_nil inherited.configuration.fetch("runner_tool_names")
    assert_equal [], disabled.configuration.fetch("fallback_models")
    assert_equal [], disabled.configuration.fetch("tools")
    assert_equal [], disabled.configuration.fetch("runner_tool_names")
    assert_equal %w[provider-b/second provider-c/third], ordered.configuration.fetch("fallback_models")
    @catalog.replace(ordered.public_id, name: ordered.name, description: ordered.description,
      configuration: { "fallback_models" => nil })
    assert_nil catalog.fetch(ordered.public_id).configuration.fetch("fallback_models")
  end

  def test_role_publication_only_changes_metadata_and_names_are_unique
    entry = @catalog.create(name: "Investigations", description: "Reusable investigation policy",
      configuration: { "system_prompt" => "Inspect the supplied evidence", "model_mode" => "default" })
    published = @catalog.publish(entry.public_id, name: "investigator", description: "Choose for evidence gathering")

    assert_equal entry.public_id, published.public_id
    assert_equal entry.configuration, published.configuration
    assert_equal({ name: "investigator", description: "Choose for evidence gathering" }, published.to_h.fetch(:role))
    replaced = @catalog.replace(entry.public_id, name: "Renamed", description: entry.description, configuration: entry.configuration)
    assert_equal published.role, replaced.role
    other = @catalog.create(name: "Another", description: "A different configuration")
    before = writes.length
    assert_raises(Rho::AgentPresets::Error) do
      @catalog.publish(other.public_id, name: "investigator", description: "Already taken")
    end
    assert_equal before, writes.length
    assert_nil @catalog.fetch(other.public_id).role
    assert_nil @catalog.unpublish(entry.public_id).role
    assert_equal entry.configuration, @catalog.fetch(entry.public_id).configuration
  end

  def test_default_references_cannot_be_left_dangling
    main_id = @catalog.main_preset_public_id
    bot_id = @catalog.default_bot_preset_public_id
    assert_match(/main Agent/, assert_raises(Rho::AgentPresets::Error) { @catalog.remove(main_id) }.message)
    assert_match(/default Bot/, assert_raises(Rho::AgentPresets::Error) { @catalog.remove(bot_id) }.message)
    assert_raises(Rho::AgentPresets::Error) { @catalog.select_main("missing") }
    assert_equal main_id, @catalog.main_preset_public_id

    replacement = @catalog.create(name: "Replacement", description: "Explicit default")
    @catalog.select_main(replacement.public_id)
    @catalog.select_default_bot(replacement.public_id)
    @catalog.remove(main_id)
    @catalog.remove(bot_id)
    assert_equal replacement.public_id, catalog.main_preset_public_id
    assert_equal replacement.public_id, catalog.default_bot_preset_public_id
  end

  def test_invalid_authored_configuration_does_not_replace_saved_policy
    entry = @catalog.create(name: "Saved", description: "Keep this policy", configuration: { "tools" => [] })
    before = writes.length
    assert_raises(Rho::AgentPresets::Error) do
      @catalog.replace(entry.public_id, name: entry.name, description: entry.description,
        configuration: { "fallback_models" => "provider/model" })
    end
    assert_equal before, writes.length
    assert_equal entry, @catalog.fetch(entry.public_id)
  end

  def test_unavailable_store_does_not_become_a_fresh_catalog
    @store.fail_reads(CybrosAgent::TransportError.new("offline"))
    assert_raises(CybrosAgent::TransportError) { @catalog.list }
    assert_empty @store.rows
  end

  private

    def catalog = Rho::AgentPresets.new(store: -> { @profile.store_entries })

    def writes = @store.calls.select { |call| %i[create update delete].include?(call.first) }
end
