require "test_helper"

# The built-in sources and declared template variables share one substitution pass.
class Nexus::PromptMacrosTest < ActiveSupport::TestCase
  Macros = Nexus::PromptMacros

  test "the registry names the built-in sources" do
    assert_equal %w[agent user workspace date conversation_kind], Macros::REGISTRY
  end

  test "the built-in sources substitute, spaces inside the braces allowed" do
    rendered = Macros.render(
      "{{agent}} serves {{ user }} in {{workspace}} on {{date}}; {{conversation_kind}}.",
      { "agent" => "rho", "user" => "Ada", "workspace" => "Shared", "date" => "2026-09-08",
        "conversation_kind" => "scheduled" }
    )
    assert_equal "rho serves Ada in Shared on 2026-09-08; scheduled.", rendered
  end

  test "a nil source renders empty, never the braces" do
    assert_equal "Hello  and .",
      Macros.render("Hello {{agent}} and {{user}}.", { "agent" => nil, "user" => nil, "workspace" => "w", "date" => "d" })
  end

  test "an unknown name is named; a known set answers nil" do
    assert_equal "history", Macros.unknown("Recall {{history}} and {{ date }}")
    assert_nil Macros.unknown("{{agent}} {{user}} {{workspace}} {{date}} {{conversation_kind}}")
    assert_nil Macros.unknown("no macros at all")
  end

  test "text without a registry name is left byte for byte, braces included" do
    assert_equal "keep {{ this }} alone",
      Macros.render("keep {{ this }} alone", agent: "a", user: "u", workspace: "w", date: "d")
  end
end
