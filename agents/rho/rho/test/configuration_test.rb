require_relative "test_helper"
require "rho/configuration"

class ConfigurationTest < Minitest::Test
  def test_current_fields_keep_sparse_intent_and_default_invalid_values
    schema = Rho::Configuration::Schema.new(
      "type" => "object",
      "properties" => {
        "enabled" => { "type" => "boolean", "default" => true },
        "port" => { "type" => "integer", "minimum" => 1, "maximum" => 65_535, "default" => 3773 },
        "zero" => { "type" => "integer", "minimum" => 0 },
        "label" => { "type" => "string" },
        "nullable" => { "type" => ["string", "null"], "default" => "inherited" },
      }
    )

    result = schema.normalize("enabled" => false, "port" => 70_000, "zero" => 0, "label" => "", "nullable" => nil, "old" => "ignored")

    assert_equal({ "enabled" => false, "zero" => 0, "label" => "", "nullable" => nil }, result.overrides)
    assert_equal result.overrides.merge("port" => 3773), result.value
    assert_equal [["port"], ["old"]], result.diagnostics.map(&:path)
    assert_equal %w[maximum unknown_field], result.diagnostics.map(&:reason)
    assert_equal %w[default unset], result.diagnostics.map(&:fallback)
    assert_equal({}, schema.normalize({}).overrides)
    assert_equal({ "enabled" => true, "port" => 3773, "nullable" => "inherited" }, schema.normalize({}).value)
    assert_equal({ "port" => 3773 }, schema.normalize("port" => 3773).overrides)
  end

  def test_nested_objects_preserve_valid_siblings_and_map_names_are_literal
    result = connection_schema.normalize(
      "connections" => {
        "host.example" => { "command" => "mcp", "retries" => -1, "token" => "private", "extra" => true },
        "empty" => {},
      }
    )

    assert_equal({ "command" => "mcp", "token" => "private" }, result.overrides.dig("connections", "host.example"))
    assert_equal 3, result.value.dig("connections", "host.example", "retries")
    assert_equal({ "retries" => 3 }, result.value.dig("connections", "empty"))
    assert_equal ["connections", "host.example", "retries"], result.diagnostics.first.path
  end

  def test_invalid_arrays_fall_back_whole_while_valid_empty_arrays_survive
    schema = Rho::Configuration::Schema.new(
      "type" => "object", "properties" => {
        "rules" => { "type" => "array", "items" => { "type" => "integer", "minimum" => 0 }, "default" => [1, 2] },
      }
    )
    result = schema.normalize("rules" => [3, -1, 4])

    assert_equal({}, result.overrides)
    assert_equal({ "rules" => [1, 2] }, result.value)
    assert_equal ["rules"], result.diagnostics.fetch(0).path
    assert_equal({ "rules" => [] }, schema.normalize("rules" => []).overrides)
  end

  def test_required_setup_fields_can_remain_unset_but_are_diagnosed
    schema = Rho::Configuration::Schema.new(
      "type" => "object", "required" => ["endpoint"], "properties" => {
        "endpoint" => { "type" => "string", "minLength" => 1 },
        "port" => { "type" => "integer", "default" => 80 },
      }
    )
    result = schema.edit({}, operations: [{ "op" => "set", "path" => ["port"], "value" => 81 }])

    assert_equal({ "port" => 81 }, result.overrides)
    assert_equal "required", result.diagnostics.fetch(0).reason
    assert_equal({ "port" => 80 }, schema.normalize("invalid object").value)
  end

  def test_field_batches_preserve_unedited_secrets_and_reset_only_the_override
    schema = connection_schema
    raw = {
      "connections" => {
        "host.example" => { "command" => "old", "token" => "private", "retries" => -1 },
        "other" => { "command" => "untouched", "token" => "other-private" },
      },
    }
    first = schema.edit(raw, operations: [{ "op" => "set", "path" => ["connections", "host.example", "command"], "value" => "new" }])
    second = schema.edit(first.overrides, operations: [{ "op" => "set", "path" => ["connections", "host.example", "retries"], "value" => 3 }])
    reset = schema.edit(second.overrides, operations: [{ "op" => "unset", "path" => ["connections", "host.example", "retries"] }])

    assert_equal "private", reset.overrides.dig("connections", "host.example", "token")
    assert_equal "new", reset.overrides.dig("connections", "host.example", "command")
    assert_equal raw.dig("connections", "other"), reset.overrides.dig("connections", "other")
    assert_equal 3, second.overrides.dig("connections", "host.example", "retries")
    refute reset.overrides.fetch("connections").fetch("host.example").key?("retries")
    assert_equal 3, reset.value.dig("connections", "host.example", "retries")
    assert_equal(-1, raw.dig("connections", "host.example", "retries"))
    assert_equal "minimum", first.diagnostics.fetch(0).reason
  end

  def test_invalid_explicit_edits_refuse_without_changing_input
    schema = connection_schema
    raw = { "connections" => { "test" => { "command" => "mcp" } } }

    error = assert_raises(Rho::ConfigurationError) do
      schema.edit(raw, operations: [{ "op" => "set", "path" => ["connections", "test", "retries"], "value" => "private-rejected-value" }])
    end
    refute_includes error.message, "private-rejected-value"
    assert_equal({ "connections" => { "test" => { "command" => "mcp" } } }, raw)
    assert_raises(Rho::ConfigurationError) do
      schema.edit(raw, operations: [{ "op" => "set", "path" => ["connections", "test", "missing"], "value" => true }])
    end
  end

  def test_edits_follow_batch_order_and_map_removal_includes_secrets
    schema = connection_schema
    result = schema.edit({}, operations: [
      { "op" => "set", "path" => ["connections", "test"], "value" => { "command" => "first", "token" => "private" } },
      { "op" => "set", "path" => ["connections", "test", "command"], "value" => "last" },
    ])
    assert_equal "last", result.value.dig("connections", "test", "command")
    removed = schema.edit(result.overrides, operations: [{ "op" => "unset", "path" => ["connections", "test"] }])
    assert_equal({}, removed.overrides.fetch("connections"))
    assert_empty schema.view(removed).secrets
  end

  def test_array_edits_require_the_whole_field
    schema = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "args" => { "type" => "array", "items" => { "type" => "string" } },
    })
    assert_raises(Rho::ConfigurationError) do
      schema.edit({ "args" => ["a"] }, operations: [{ "op" => "set", "path" => ["args", "0"], "value" => "b" }])
    end
    result = schema.edit({ "args" => ["a"] }, operations: [{ "op" => "set", "path" => ["args"], "value" => [] }])
    assert_equal({ "args" => [] }, result.overrides)
  end

  def test_batch_edits_reject_group_fallback_and_validate_the_completed_batch
    schema = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "selection" => { "type" => "object", "minProperties" => 1, "maxProperties" => 1,
        "additionalProperties" => { "type" => "string" } },
      "unrelated" => { "type" => "integer", "default" => 2 },
    })
    original = { "selection" => { "first" => "one" }, "unrelated" => "invalid-existing-value" }
    add = { "op" => "set", "path" => ["selection", "second"], "value" => "two" }
    remove = { "op" => "unset", "path" => ["selection", "first"] }

    assert_raises(Rho::ConfigurationError) { schema.edit(original, operations: [add]) }
    assert_raises(Rho::ConfigurationError) { schema.edit(original, operations: [remove]) }
    result = schema.edit(original, operations: [remove, add])

    assert_equal({ "selection" => { "second" => "two" } }, result.overrides)
    assert_equal 2, result.value.fetch("unrelated")
    assert_equal({ "first" => "one" }, original.fetch("selection"))
  end

  def test_secret_views_omit_values_and_schema_annotations_but_report_presence
    schema = connection_schema
    result = schema.normalize("connections" => { "one" => { "token" => "never-return", "command" => "mcp" }, "two" => {} })
    view = schema.view(result)
    encoded = JSON.generate(view.to_h)

    refute_includes encoded, "never-return"
    assert_equal "mcp", view.overrides.dig("connections", "one", "command")
    assert_equal [
      { path: ["connections", "one", "token"], set: true },
      { path: ["connections", "two", "token"], set: false },
    ], view.to_h.fetch(:secrets)
    refute view.value.fetch("connections").fetch("one").key?("token")

    defaults = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "auth" => {
        "type" => "object", "default" => { "token" => "default-secret" },
        "examples" => [{ "token" => "example-secret" }],
        "properties" => { "token" => { "type" => "string", "writeOnly" => true, "examples" => ["field-secret"] } },
      },
    })
    document = JSON.generate(defaults.view(defaults.normalize({})).to_h)
    %w[default-secret example-secret field-secret].each { |secret| refute_includes document, secret }
    assert defaults.view(defaults.normalize({})).secrets.fetch(0).set
  end

  def test_invalid_defaults_and_unsupported_authoring_fail_at_compilation
    [
      { "type" => "integer", "minimum" => 1, "default" => 0 },
      { "type" => "object", "properties" => {}, "default" => { "unknown" => true } },
      { "type" => "string", "oneOf" => [{ "const" => "a" }] },
      { "type" => "string", "$ref" => "https://example.test/schema" },
      { "type" => "array" },
    ].each do |property|
      assert_raises(Rho::ConfigurationError) do
        Rho::Configuration::Schema.new("type" => "object", "properties" => { "setting" => property })
      end
    end
  end

  def test_public_schema_keeps_false_and_null_choices_and_hides_secret_descendants
    schema = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "choice" => { "type" => ["boolean", "null"], "enum" => [false, nil], "examples" => [false, nil] },
      "secrets" => {
        "type" => "object", "writeOnly" => true, "properties" => {
          "key" => { "type" => "string", "default" => "nested-secret", "examples" => ["nested-example"] },
        },
      },
      "credentials" => {
        "type" => "array", "items" => {
          "type" => "object", "properties" => {
            "name" => { "type" => "string" },
            "token" => { "type" => "string", "writeOnly" => true },
          },
        },
      },
    })
    view = schema.view(schema.normalize("credentials" => [{ "name" => "one", "token" => "array-secret" }]))
    assert_equal [false, nil], view.schema.dig("properties", "choice", "enum")
    assert_equal [false, nil], view.schema.dig("properties", "choice", "examples")
    assert_equal [{ "name" => "one" }], view.value.fetch("credentials")
    %w[nested-secret nested-example array-secret].each { |secret| refute_includes JSON.generate(view.to_h), secret }
    assert_equal ["credentials", "0", "token"], view.secrets.last.path
  end

  def test_object_default_gets_nested_defaults_without_becoming_an_override
    schema = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "options" => { "type" => "object", "default" => {}, "properties" => { "limit" => { "type" => "integer", "default" => 2 } } },
    })
    result = schema.normalize({})
    assert_equal({ "options" => { "limit" => 2 } }, result.value)
    assert_equal({}, result.overrides)
  end

  def test_coupled_object_and_default_are_rejected_when_defaults_break_the_group
    assert_raises(Rho::ConfigurationError) do
      Rho::Configuration::Schema.new("type" => "object", "properties" => {
        "options" => {
          "type" => "object", "default" => {}, "enum" => [{}],
          "properties" => { "limit" => { "type" => "integer", "default" => 2 } },
        },
      })
    end
  end

  def test_migration_rejects_non_json_output
    assert_raises(Rho::ConfigurationError) do
      Rho::Configuration.migrate({}, from: 0, to: 1, steps: { 1 => ->(_document) { Object.new } })
    end
  end

  def test_missing_constrained_object_does_not_loop_or_guess_a_value
    schema = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "selection" => { "type" => "object", "minProperties" => 1, "properties" => { "key" => { "type" => "string" } } },
    })
    assert_equal({}, schema.normalize({}).value)
    assert_equal({}, schema.normalize("selection" => {}).value)
  end

  def test_nullable_field_still_obeys_enum
    schema = Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "choice" => { "type" => ["string", "null"], "enum" => ["a"], "default" => "a" },
    })
    assert_equal({ "choice" => "a" }, schema.normalize("choice" => nil).value)
  end

  def test_migrations_run_in_order_without_mutating_the_original_document
    original = { "old" => "kept" }
    order = []
    migrated = Rho::Configuration.migrate(original, from: 0, to: 2, steps: {
      1 => ->(document) { order << 1; document["new"] = document.delete("old"); document },
      2 => ->(document) { order << 2; document.merge("added" => true) },
    })
    assert_equal [1, 2], order
    assert_equal({ "new" => "kept", "added" => true }, migrated)
    assert_equal({ "old" => "kept" }, original)
    assert_equal original, Rho::Configuration.migrate(original, from: 2, to: 2, steps: {})
  end

  def test_failed_missing_or_newer_migrations_refuse_without_exposing_values
    original = { "token" => "private" }
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Configuration.migrate(original, from: 0, to: 1, steps: {
        1 => ->(document) { document.clear; raise "private" },
      })
    end
    refute_includes error.message, "private"
    assert_nil error.cause
    assert_equal({ "token" => "private" }, original)
    assert_raises(Rho::ConfigurationError) { Rho::Configuration.migrate(original, from: 0, to: 1, steps: {}) }
    assert_raises(Rho::ConfigurationError) { Rho::Configuration.migrate(original, from: 2, to: 1, steps: {}) }
  end

  private

  def connection_schema
    Rho::Configuration::Schema.new("type" => "object", "properties" => {
      "connections" => {
        "type" => "object", "additionalProperties" => {
          "type" => "object", "properties" => {
            "command" => { "type" => "string" },
            "retries" => { "type" => "integer", "minimum" => 0, "default" => 3 },
            "token" => { "type" => "string", "writeOnly" => true },
          },
        },
      },
    })
  end
end
