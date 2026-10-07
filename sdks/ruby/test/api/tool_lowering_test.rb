require "test_helper"

# MCP `Tool` → the provider's function entry. It lives in the SDK rather
# than in the kernel because `Tool` is purely ADDITIVE across every MCP
# revision: a kernel-side converter would be a standing cache bomb, since
# the deploy that first honours a newly-added field would rewrite the front
# of every live cached prefix with no agent change at all.
class ApiToolLoweringTest < Minitest::Test
  Lowering = CybrosAgent::Api::ToolLowering

  READ = {
    "name" => "read",
    "description" => "Read a file",
    "inputSchema" => { "type" => "object",
                       "properties" => { "path" => { "type" => "string" } },
                       "required" => ["path"] },
  }.freeze

  def test_it_produces_the_shape_the_kernel_stores
    entry = Lowering.function_entry(READ)

    assert_equal "function", entry.fetch("type")
    function = entry.fetch("function")
    assert_equal %w[name description parameters], function.keys,
      "fixed key order: these bytes are the front of every cached prefix"
    assert_equal "read", function.fetch("name")
    assert_equal READ.fetch("inputSchema"), function.fetch("parameters")
  end

  # EVERY OTHER FIELD DROPPED BY CONSTRUCTION. A field MCP adds tomorrow
  # must move zero cached bytes until an agent upgrades on purpose, which
  # is only true if the lowering builds a new Hash rather than transforming
  # whatever arrived.
  def test_an_unknown_member_cannot_reach_the_wire
    entry = Lowering.function_entry(READ.merge(
      "title" => "Read", "annotations" => { "readOnlyHint" => true }, "_meta" => { "x" => 1 }
    ))

    assert_equal Lowering.function_entry(READ), entry,
      "a purely additive vocabulary must not silently rewrite a cached prefix"
  end

  # A tool with no schema takes NO arguments — not arbitrary ones. Omitting
  # the member is how a model learns it may invent parameters.
  def test_a_missing_schema_becomes_an_empty_object_not_an_absence
    function = Lowering.function_entry(
      "name" => "ping", "description" => "Ping"
    ).fetch("function")

    assert_equal({ "type" => "object", "properties" => {} }, function.fetch("parameters"))
  end

  def test_a_snake_cased_schema_key_is_accepted_because_ruby_writes_it_that_way
    function = Lowering.function_entry(
      "name" => "ping", "input_schema" => { "type" => "object", "properties" => { "n" => {} } }
    ).fetch("function")

    assert_equal({ "n" => {} }, function.fetch("parameters").fetch("properties"))
  end

  def test_a_missing_description_is_empty_rather_than_nil
    function = Lowering.function_entry("name" => "ping").fetch("function")
    assert_equal "", function.fetch("description")
  end

  def test_a_nameless_tool_is_refused_rather_than_lowered_to_nothing
    assert_raises(ArgumentError) { Lowering.function_entry("description" => "no name") }
    assert_raises(ArgumentError) { Lowering.function_entry("name" => "") }
    assert_raises(ArgumentError) { Lowering.function_entry("not a hash") }
  end

  # THE LIST IS A SET. The kernel canonicalizes by name on the way in for
  # exactly this reason; sorting here means the bytes a caller sends
  # already match the bytes the kernel stores, so re-authoring the same
  # tools in a different order cannot bust the caller's own cache.
  def test_the_list_is_sorted_so_authoring_order_cannot_bust_a_cache
    forward = Lowering.function_entries([READ, { "name" => "bash" }, { "name" => "write" }])
    shuffled = Lowering.function_entries([{ "name" => "write" }, READ, { "name" => "bash" }])

    assert_equal %w[bash read write], forward.map { |e| e.dig("function", "name") }
    assert_equal forward, shuffled
    assert_equal JSON.generate(forward), JSON.generate(shuffled), "byte-identical, not merely equal"
  end

  def test_an_empty_list_lowers_to_an_empty_list
    assert_empty Lowering.function_entries(nil)
    assert_empty Lowering.function_entries([])
  end
end
