require "test_helper"

# THE HOLE THIS CLOSES: a task declaring a kernel tool must send
# BYTE-IDENTICAL bytes, because the tools block is the front of every
# cached prefix and `kernel_tool_redefined` refuses any paraphrase. That
# rule is right, and until this route existed the canonical bytes were
# computed, used to REFUSE, and never published — so a client had to
# transcribe them from the source and any drift became an authoring-time
# refusal it could not fix.
class AgentAPI::V1::ToolsTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @token = create_access_token_fixture(user: @human, name: "Member")
  end

  def auth = { "Authorization" => "Bearer #{@token.secret}" }

  def compile(steps) = AgentRuns::Tasks::Compile.call(steps, AgentRuns::Tasks::Tip.seed("round"))

  test "the catalog publishes exactly the bytes a task must send" do
    get "/agent_api/v1/tools", headers: auth
    assert_response :success

    tools = response.parsed_body.fetch("tools")
    assert_equal Nexus::ToolRegistry.live_names.sort,
      tools.map { |tool| tool.fetch("canonical_name") }.sort

    # THE ASSERTION THAT MATTERS: what this serves is what the compile
    # door demands. Anything else and a client following the catalog is
    # refused by the kernel that published it.
    tools.each do |tool|
      canonical = tool.fetch("canonical_name")
      assert_equal(
        JSON.parse(Nexus::ToolRegistry.function_definition(canonical).to_json),
        tool.fetch("definition"),
        "#{canonical}'s published bytes must be the bytes compile accepts"
      )
    end
  end

  test "a task built from the catalog is accepted; one word changed is not" do
    get "/agent_api/v1/tools", headers: auth
    published = response.parsed_body.fetch("tools")
      .find { |tool| tool.fetch("name") == "memory_read" }.fetch("definition")

    accepted = compile([model("m1", "prompt" => "go", "tools" => [published])])
    assert_predicate accepted, :valid?, accepted.errors.inspect

    paraphrased = published.deep_dup
    paraphrased["function"]["description"] = "durable memory"
    refused = compile([model("m1", "prompt" => "go", "tools" => [paraphrased])])
    assert_equal "kernel_tool_redefined", refused.errors.sole.fetch("code"),
      "a paraphrase is a second cached prefix describing a tool that behaves otherwise"
  end

  test "the catalog carries the effect profile, which never rides the model wire" do
    get "/agent_api/v1/tools", headers: auth
    tool = response.parsed_body.fetch("tools").first

    assert_equal Nexus::ToolRegistry::EFFECT_KEYS.sort,
      tool.fetch("effect_profile").keys.sort
    refute tool.fetch("definition").fetch("function").key?("effect_profile"),
      "trusted metadata is for the host, never for the model's wire"
  end

  # THE TEMPLATE: the description's macro- bearing SOURCE beside the plain render, so an adaptation
  # pack's `recut` edits ONE anchored paragraph of the kernel's own bytes instead of carrying a copy
  # of them — and a paragraph the kernel re-cuts fails the pack's anchor loudly instead of drifting.
  # The plain `definition` is exactly that source with its macros spelled as the kernel's wire
  # names; a template with no macro would leave a recut nothing to prove.
  test "the catalog serves each description's macro-bearing source beside the plain render" do
    get "/agent_api/v1/tools", headers: auth
    tools = response.parsed_body.fetch("tools")

    tools.each do |tool|
      entry = Nexus::ToolRegistry.entry(tool.fetch("canonical_name"))
      assert_equal entry.template, tool.fetch("template"), "#{entry.canonical}'s source, verbatim"
      assert_equal Nexus::ToolRegistry.render_text(entry.template),
        tool.dig("definition", "function", "description"),
        "#{entry.canonical}: the plain render is the template with its macros spelled as the kernel's names"
    end
    assert tools.any? { |tool| tool.fetch("template").match?(Nexus::ToolRegistry::MACRO) },
      "the source carries macros, or the plain render would be the source"
  end
end
