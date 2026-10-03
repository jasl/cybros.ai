require "test_helper"

# THE SHIPPED EXAMPLE: Context7 rides in every rho as ONE row of `mcp_servers` the gem
# carries, PRESENT and DISABLED — merged UNDER the person's table the way `checkpoints`
# merges its defaults under the person's object: the person's rows first in their order,
# the shipped row after; a person's row under the same key overlays it member by member
# (`{"enabled": true}` is what `rho mcp enable context7` writes); a value that is not an
# object passes through to the grammar's own refusal.
class BuiltinTest < Minitest::Test
  CONTEXT7 = { "transport" => "http", "url" => "https://mcp.context7.com/mcp", "tools" => "*", "enabled" => false }.freeze
  FX = { "transport" => "stdio", "command" => "ruby", "tools" => ["echo"] }.freeze

  def test_the_one_shipped_row_is_context7_disabled
    assert_equal({ "context7" => CONTEXT7 }, Rho::Mcp::Builtin::ROWS)
    assert_predicate Rho::Mcp::Builtin::ROWS, :frozen?
    assert_predicate Rho::Mcp::Builtin::ROWS.fetch("context7"), :frozen?
  end

  def test_a_fresh_table_carries_the_shipped_row_after_the_persons_rows
    table = Rho::Mcp::Builtin.under({ "zz" => FX, "fx" => FX })
    assert_equal %w[zz fx context7], table.keys
    assert_equal CONTEXT7, table.fetch("context7")
    assert_equal FX, table.fetch("fx"), "the person's rows ride untouched"
    assert_equal({ "context7" => CONTEXT7 }, Rho::Mcp::Builtin.under({}))
    assert_equal({ "context7" => CONTEXT7, "fx" => FX }, Rho::Mcp::Builtin.under({ context7: {}, fx: FX }).slice("context7", "fx"),
      "symbol keys read as the grammar reads them")
  end

  def test_a_persons_row_under_the_shipped_key_overlays_it_member_by_member
    table = Rho::Mcp::Builtin.under({ "context7" => { "enabled" => true } })
    assert_equal CONTEXT7.merge("enabled" => true), table.fetch("context7")
    table = Rho::Mcp::Builtin.under({ "context7" => { "tools" => ["get-library-docs"], "timeout_ms" => 5000 } })
    assert_equal CONTEXT7.merge("tools" => ["get-library-docs"], "timeout_ms" => 5000), table.fetch("context7"), "the rest of the row stands"
    table = Rho::Mcp::Builtin.under({ "context7" => { "enabled" => true }, "fx" => FX })
    assert_equal %w[context7 fx], table.keys, "the person's order, where the person named the key"
  end

  def test_a_value_that_is_not_an_object_passes_through_to_the_grammars_refusal
    assert_equal ["fx"], Rho::Mcp::Builtin.under(["fx"])
    table = Rho::Mcp::Builtin.under({ "context7" => "ruby" })
    assert_equal "ruby", table.fetch("context7")
    error = assert_raises(Rho::Mcp::Settings::Malformed) { Rho::Mcp::Settings.parse(table) }
    assert_equal "mcp_servers[context7] must be an object", error.message
  end

  def test_the_shipped_row_parses_disabled_on_the_agent_address_and_oauth_capable
    row = Rho::Mcp::Settings.parse(Rho::Mcp::Builtin.under({})).fetch(0)
    assert_kind_of Rho::Mcp::Settings::Row, row
    assert_equal ["context7", "http", "https://mcp.context7.com/mcp", :agent, false],
      row.to_h.values_at(:key, :transport, :url, :serves, :enabled)
    refute_predicate row, :enabled?
    assert_predicate row, :oauth?
    assert_predicate row, :all_tools?
    assert_empty row.secrets
  end
end
