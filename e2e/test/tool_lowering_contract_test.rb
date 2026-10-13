require "test_helper"

# THE ONE CONVERSION THAT SPANS BOTH SIDES, checked against the kernel's
# own bytes rather than against a fixture of them.
#
# An agent declaring a tool on a model task sends the PROVIDER function
# shape; a runner publishes the MCP `Tool` shape. The lowering between them
# lives in the agent's SDK deliberately (`Tool` is purely additive across
# MCP revisions, so a kernel-side converter would rewrite the front of every
# live cached prefix the day it honoured a new field). That placement is
# only safe if the lowering agrees with the kernel EXACTLY: `Compile`
# refuses `kernel_tool_redefined` unless a declared kernel tool is
# byte-identical to what the registry publishes, so a single reordered key
# here makes every kernel tool undeclarable by an agent.
#
# Offline: the registry is a constant table and the lowering is a pure
# function. No server, no provider, no database.
class ToolLoweringContractTest < Minitest::Test
  REGISTRY = File.expand_path("../../nexus/lib/nexus/tool_registry.rb", __dir__)

  # Loaded, not reimplemented — a copy of the table here would agree with
  # itself forever and with nexus never.
  def registry
    @registry ||= begin
      unless defined?(Nexus::ToolRegistry)
        require "active_support/all"
        load REGISTRY
      end
      Nexus::ToolRegistry
    end
  end

  def test_every_live_kernel_tool_lowers_to_the_kernels_own_bytes
    names = registry.live_names
    refute_empty names, "an empty registry would make this test vacuous"

    names.each do |canonical|
      published = registry.function_definition(canonical)
      wire = published.fetch("function")

      # What a runner would publish for the same tool, in MCP's vocabulary.
      as_mcp = {
        "name" => wire.fetch("name"),
        "description" => wire.fetch("description"),
        "inputSchema" => wire["parameters"],
      }

      lowered = CybrosAgent::Api::ToolLowering.function_entry(as_mcp)

      assert_equal JSON.generate(published), JSON.generate(lowered),
        "#{canonical} lowers to different bytes than the registry publishes — " \
        "an agent declaring it would be refused kernel_tool_redefined"
    end
  end

  # The kernel canonicalizes a task's tool list by name on the way in. A
  # caller whose own list is sorted differently would store different bytes
  # than it sent and bust its own prompt cache on the next turn.
  def test_the_lowered_list_is_already_in_the_order_the_kernel_stores
    names = registry.live_names
    tools = names.map do |canonical|
      wire = registry.function_definition(canonical).fetch("function")
      { "name" => wire.fetch("name"), "description" => wire.fetch("description"),
        "inputSchema" => wire["parameters"] }
    end

    lowered = CybrosAgent::Api::ToolLowering.function_entries(tools.shuffle)
    kernel_order = lowered.sort_by { |entry| entry.dig("function", "name") }

    assert_equal JSON.generate(kernel_order), JSON.generate(lowered)
  end
end
