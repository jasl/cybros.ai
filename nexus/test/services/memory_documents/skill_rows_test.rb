require "test_helper"

# THE WRITER'S FOUR SKILL REFUSALS, at the one writer both doors call: a `skills/` path needs a name
# under the skill grammar, a rung that is not the conversation's, and a description; a plain
# document takes none. The prefix is the kind.
class MemoryDocuments::SkillRowsTest < ActiveSupport::TestCase
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
  end

  def anchor(path)
    Scopes::Anchor.call(path: path, workspace: @workspace, conversation: @conversation, user: @human)
  end

  def write(path, content = "body", description: nil)
    resolved = anchor(path)
    MemoryDocument.transaction do
      resolved.lockable.lock!
      MemoryDocuments::Write.call(anchor: resolved, expected: memory_expectation_at(resolved), content: content, description: description)
    end
  end

  test "a skills/ row lands with its description on the workspace and user rungs" do
    result = write("workspace/skills/commit-style", description: "How this team writes commits.")
    assert_predicate result, :written?
    assert_equal "How this team writes commits.", result.document.description
    assert_predicate result.document, :skill?

    mine = write("user/skills/review", description: "How I review.")
    assert_predicate mine, :written?
    assert_equal "user/skills/review", mine.document.path
  end

  test "a rewrite replaces the description with the write's own" do
    write("workspace/skills/commit-style", description: "first")
    result = write("workspace/skills/commit-style", "v2", description: "second")
    assert_predicate result, :written?
    assert_equal "second", result.document.reload.description
    assert_equal "v2", result.document.content
  end

  test "skill_description_required: a skills/ write with no description, or a blank one" do
    assert_equal :skill_description_required, write("workspace/skills/commit-style").outcome
    assert_equal :skill_description_required, write("workspace/skills/commit-style", description: "  \n").outcome
    assert_equal :skill_description_required, write("workspace/skills/commit-style", description: "").outcome
  end

  test "memory_description_invalid: not a string, over 1024 bytes, or given outside skills/" do
    assert_equal :memory_description_invalid, write("workspace/skills/x", description: 3).outcome
    assert_equal :memory_description_invalid, write("workspace/skills/x", description: ["a"]).outcome
    assert_equal :memory_description_invalid, write("workspace/skills/x", description: "x" * 1025).outcome
    assert_predicate write("workspace/skills/x", description: "x" * 1024), :written?
    # Bytes, not characters: the line a model reads is bounded in bytes.
    assert_equal :memory_description_invalid, write("workspace/skills/y", description: "é" * 600).outcome
    assert_equal :memory_description_invalid, write("workspace/notes.md", description: "a plain note").outcome
    assert_not MemoryDocument.for_workspace(@workspace.id).exists?(name: "notes.md")
  end

  test "skill_name_invalid: the remainder must be a skill name — no nesting, no case, no bare prefix" do
    %w[skills/ skills/a/b skills/PDF skills/pdf_extract skills/-pdf].each do |name|
      assert_equal :skill_name_invalid, write("workspace/#{name}", description: "d").outcome, name
    end
    assert_equal :skill_name_invalid, write("workspace/skills/#{"a" * 65}", description: "d").outcome
  end

  test "skill_scope_unavailable: a skill is never per conversation" do
    assert_equal :skill_scope_unavailable, write("conversation/skills/plan", description: "d").outcome
    assert_not MemoryDocument.for_conversation(@conversation.id).exists?
  end

  test "the refusals come in the design's order: name, then scope, then description" do
    assert_equal :skill_name_invalid, write("conversation/skills/PDF").outcome
    assert_equal :skill_scope_unavailable, write("conversation/skills/pdf").outcome
  end

  test "a plain write is unchanged: no description, no refusal, description null" do
    result = write("workspace/notes.md", "n")
    assert_predicate result, :written?
    assert_nil result.document.description
  end

  test "the listing carries the description beside the path" do
    write("workspace/skills/commit-style", description: "How this team writes commits.")
    write("workspace/notes.md", "n")
    entries = MemoryDocuments::Listing.call(documents: MemoryDocument.for_workspace(@workspace.id))
    assert_equal [["workspace/notes.md", nil], ["workspace/skills/commit-style", "How this team writes commits."]],
      entries.map { |entry| [entry.path, entry.description] }
  end
end
