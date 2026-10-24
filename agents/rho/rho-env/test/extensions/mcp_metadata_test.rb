require "test_helper"

class McpMetadataTest < Minitest::Test
  Tool = Rho::Env::Extensions::Tool

  def tool(metadata = nil)
    Class.new do
      const_set(:NAME, "mcp_like_name")
      const_set(:DESCRIPTION, "An ordinary tool unless its source declares MCP metadata")
      const_set(:SCHEMA, { "type" => "object", "properties" => {} })
      const_set(:EFFECT_PROFILE, Rho::Env::Tools::Read::EFFECT_PROFILE)
      const_set(:MCP, metadata) unless metadata.nil?
      define_method(:call) { |_arguments| nil }
    end
  end

  def test_metadata_survives_announcement_without_entering_the_model_schema
    metadata = { "server_key" => "Editor / work", "tool_name" => "notes.search" }
    klass = tool(metadata)
    Tool.validate(klass, extension: "fixture")
    announcement = Tool.announcement(klass, name: klass::NAME)

    assert_equal metadata, announcement.fetch("mcp")
    refute Tool.announcement(tool, name: "mcp_like_name").key?("mcp")
    definition = CybrosAgent::Api::ToolLowering.function_entry(
      "name" => announcement.fetch("name"), "description" => announcement.fetch("description"),
      "inputSchema" => announcement.fetch("input_schema"))
    refute definition.key?("mcp")
    refute definition.fetch("function").key?("mcp")
  end

  def test_invalid_metadata_is_refused_at_registration
    [{}, { "server_key" => "work", "tool_name" => "" },
     { "server_key" => "work", "tool_name" => 12 },
     { "server_key" => "work", "tool_name" => "search", "token" => "fixture" }].each do |metadata|
      assert_raises(Rho::Env::Extensions::RegistrationError) { Tool.validate(tool(metadata), extension: "fixture") }
    end
  end
end
