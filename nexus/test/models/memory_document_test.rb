require "test_helper"

# THE THREE RUNGS ON ONE ROW: exactly one of conversation, workspace, user anchors a document. There
# is no CHECK constraint — the model validation is the one arbiter, and the three partial unique
# indexes are the structural backstop.
class MemoryDocumentTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:owner)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @version = MemoryDocumentVersion.create!(account: @account, content: "x")
  end

  def build(**anchor)
    MemoryDocument.new(account: @account, name: "notes.md",
      memory_document_version: @version, **anchor)
  end

  test "the scopes are the three rungs of the ladder" do
    assert_equal %w[conversation workspace user], MemoryDocument::SCOPES
  end

  test "exactly one anchor: two are invalid, none is invalid, a user alone is valid" do
    assert_not build(conversation: @conversation, user: @human).valid?
    assert_not build(workspace: @workspace, user: @human).valid?
    assert_not build.valid?
    assert_predicate build(user: @human), :valid?
    assert_predicate build(workspace: @workspace), :valid?
    assert_predicate build(conversation: @conversation), :valid?
  end

  test "for_user lists that person's rows only, never a workspace row" do
    mine = build(user: @human).tap(&:save!)
    build(workspace: @workspace).save!
    build(user: users(:member)).save!

    assert_equal [mine.id], MemoryDocument.for_user(@human.id).pluck(:id)
  end

  test "the path spells the scope first, and path_for is the one derivation" do
    assert_equal "user/notes.md", build(user: @human).path
    assert_equal "user/notes.md",
      MemoryDocument.path_for("notes.md", conversation_id: nil, workspace_id: nil,
        user_id: @human.id)
    assert_equal "conversation/notes.md",
      MemoryDocument.path_for("notes.md", conversation_id: @conversation.id,
        workspace_id: nil, user_id: nil)
    assert_equal "workspace/notes.md",
      MemoryDocument.path_for("notes.md", conversation_id: nil,
        workspace_id: @workspace.id, user_id: nil)
  end

  test "one document per name per person — the third partial index decides" do
    build(user: @human).save!
    assert_raises ActiveRecord::RecordNotUnique do
      build(user: @human).save!(validate: false)
    end
    assert_nothing_raised { build(user: users(:member)).save! }
  end

  test "the anchor is creation-frozen on every rung" do
    document = build(user: @human).tap(&:save!)
    assert_raises ActiveRecord::ReadonlyAttributeError do
      document.update!(user: users(:member))
    end
  end

  # A SKILL IS A ROW UNDER `skills/`: the prefix is the kind, said once in SQL for the two scopes
  # and once in Ruby.
  test "skills and not_skills are the one prefix predicate in SQL; skill? is the prefix alone" do
    skill = build(user: @human).tap { |row| row.name = "skills/review"; row.description = "how I review"; row.save! }
    plain = build(user: @human).tap(&:save!)
    trap = build(user: @human).tap { |row| row.name = "my-skills/x"; row.save! }

    assert_equal [skill.id], MemoryDocument.for_user(@human.id).skills.pluck(:id)
    assert_equal [plain.id, trap.id].sort, MemoryDocument.for_user(@human.id).not_skills.pluck(:id).sort
    assert_predicate skill, :skill?
    assert_not_predicate plain, :skill?
    assert_not_predicate trap, :skill?
  end

  test "the description is bounded by validation, nullable, and no database limit" do
    assert_predicate build(user: @human).tap { |row| row.description = "x" * 1024 }, :valid?
    assert_not build(user: @human).tap { |row| row.description = "x" * 1025 }.valid?
    assert_predicate build(user: @human), :valid?
    assert_nil MemoryDocument.columns_hash.fetch("description").limit
  end
end
