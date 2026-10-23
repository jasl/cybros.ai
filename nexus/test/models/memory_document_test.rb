require "test_helper"

class MemoryDocumentTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:owner)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @version = MemoryDocumentVersion.create!(account: @account, content: "x")
  end

  def build(owner: @human, collection: MemoryCollection.default_for(owner))
    MemoryDocument.new(account: @account, name: "notes.md",
      memory_document_version: @version, memory_collection: collection)
  end

  test "natural scope derives from the collection owner" do
    scopes = [@conversation, @workspace, @human].map do |owner|
      MemoryCollection.default_for(owner).natural_scope
    end
    assert_equal %i[conversation workspace user], scopes
  end

  test "a document requires a collection and each collection has exactly one owner" do
    assert_not build(collection: nil).valid?
    assert_not MemoryCollection.new(conversation: @conversation, user: @human).valid?
    assert_not MemoryCollection.new(workspace: @workspace, user: @human).valid?
    assert_not MemoryCollection.new(account: @account).valid?
    [@human, @workspace, @conversation].each { |owner| assert_predicate build(owner: owner), :valid? }
  end

  test "one collection lists only its own rows including among collections of the same owner" do
    mine = build.tap(&:save!)
    other = MemoryCollection.create_for(@human, name: "Other")
    build(collection: other).save!
    build(owner: @workspace).save!
    build(owner: users(:member)).save!
    assert_equal [mine.id], MemoryCollection.default_for(@human).memory_documents.pluck(:id)
    assert_equal 2, @human.memory_documents.count
  end

  test "the document path spells its collection's natural scope" do
    assert_equal "user/notes.md", build.path
    assert_equal "conversation/notes.md", build(owner: @conversation).path
    assert_equal "workspace/notes.md", build(owner: @workspace).path
  end

  test "one document per name per collection is enforced by the unique index" do
    build.save!
    assert_raises ActiveRecord::RecordNotUnique do
      MemoryDocument.transaction(requires_new: true) { build.save!(validate: false) }
    end
    assert_nothing_raised { build(collection: MemoryCollection.create_for(@human)).save! }
  end

  test "the collection and its owner are creation frozen" do
    document = build.tap(&:save!)
    assert_raises ActiveRecord::ReadonlyAttributeError do
      document.update!(memory_collection: MemoryCollection.default_for(users(:member)))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      document.memory_collection.update!(user: users(:member))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      document.memory_collection.update!(is_default: false)
    end
  end

  test "skills and not_skills share the prefix predicate and skill kind is the prefix alone" do
    skill = build.tap { |row| row.name = "skills/review"; row.description = "how I review"; row.save! }
    plain = build.tap(&:save!)
    trap = build.tap { |row| row.name = "my-skills/x"; row.save! }
    documents = MemoryCollection.default_for(@human).memory_documents
    assert_equal [skill.id], documents.skills.pluck(:id)
    assert_equal [plain.id, trap.id].sort, documents.not_skills.pluck(:id).sort
    assert_predicate skill, :skill?
    assert_not_predicate plain, :skill?
    assert_not_predicate trap, :skill?
  end

  test "the description is bounded by validation nullable and has no database limit" do
    assert_predicate build.tap { |row| row.description = "x" * 1024 }, :valid?
    assert_not build.tap { |row| row.description = "x" * 1025 }.valid?
    assert_predicate build, :valid?
    assert_nil MemoryDocument.columns_hash.fetch("description").limit
  end
end
