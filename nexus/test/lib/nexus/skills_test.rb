require "test_helper"

# THE ONE OWNER OF THE SKILL GRAMMAR: the prefix is the kind, the name grammar is the agentskills
# specification's — stricter than a memory name's — and the header's first words are what the
# `skill` tool's description points at.
class Nexus::SkillsTest < ActiveSupport::TestCase
  test "the prefix alone makes a document name reserved, and name_of strips it" do
    assert Nexus::Skills.reserved?("skills/deploy-notes")
    assert Nexus::Skills.reserved?("skills/")
    assert_not Nexus::Skills.reserved?("notes.md")
    assert_not Nexus::Skills.reserved?("my-skills/x")
    assert_not Nexus::Skills.reserved?(nil)
    assert_equal "deploy-notes", Nexus::Skills.name_of("skills/deploy-notes")
    assert_nil Nexus::Skills.name_of("notes.md")
  end

  test "the name grammar is the agentskills specification's: lowercase alphanumerics and single hyphens, at most 64" do
    %w[a deploy-notes pdf2 commit-style a1-b2-c3].each do |name|
      assert Nexus::Skills.skill_name?(name), name
    end
    ["", "PDF", "-pdf", "pdf-", "pdf--extract", "pdf_extract", "pdf/extract", "pdf.md", "a" * 65, nil, 3].each do |name|
      assert_not Nexus::Skills.skill_name?(name), name.inspect
    end
    assert Nexus::Skills.skill_name?("a" * 64)
  end

  test "the grammar is stricter than a memory document's name" do
    assert_match MemoryDocument::NAME_FORMAT, "skills/pdf/extract"
    assert_not Nexus::Skills.skill_name?(Nexus::Skills.name_of("skills/pdf/extract"))
  end

  test "the catalog header opens with the words the tool text quotes" do
    assert Nexus::Skills::CATALOG_HEADER.start_with?("Skills available now.")
    assert_equal 1024, Nexus::Skills::DESCRIPTION_MAX_LENGTH
    assert_equal Nexus::Skills::DESCRIPTION_MAX_LENGTH, MemoryDocument::DESCRIPTION_MAX_LENGTH
  end
end
