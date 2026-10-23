require "test_helper"

# Product paths resolve through the selected bindings and their actual owner.
# Fixture constructors cannot establish execution or member authority.
class MemoryDocuments::AnchorTest < ActiveSupport::TestCase
  setup do
    @workspace = workspaces(:shared)
    @human = users(:owner)
    @agent = users(:agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    MemoryCollection.default_for(@conversation)
  end

  def context(conversation: @conversation, principal: @human, agent: @agent)
    configuration = { "bindings" => %w[conversation workspace user agent].map do |scope|
      { "name" => scope, "access" => "read_write", "source" => { "scope" => scope } }
    end }
    MemoryDocuments::Context.new(workspace: @workspace, conversation: conversation,
      principal: principal, agent: agent, configuration: configuration)
  end

  def anchor(path, **) = context(**).resolve(path)

  test "explicit user memory resolves to the acting Human and its default collection" do
    resolved = anchor("user/notes.md")
    assert_predicate resolved, :resolved?
    assert_equal "user", resolved.scope
    assert_equal "notes.md", resolved.name
    assert_equal @human, resolved.lockable
    assert_equal memory_collections(:owner), resolved.collection
    assert_equal memory_collections(:owner).memory_documents.to_sql, resolved.documents.to_sql
  end

  test "each natural binding resolves its own owner and collection" do
    assert_equal @conversation, anchor("conversation/plan.md").lockable
    assert_equal @workspace, anchor("workspace/notes.md").lockable
    assert_equal @agent, anchor("agent/notes.md").lockable
    assert_equal @conversation.memory_collections.find_by!(is_default: true), anchor("conversation/plan.md").collection
    assert_equal memory_collections(:shared), anchor("workspace/notes.md").collection
    assert_equal memory_collections(:agent), anchor("agent/notes.md").collection
  end

  test "standalone context has no Conversation but retains its selected Workspace and Human sources" do
    assert_equal :memory_scope_unavailable, anchor("conversation/plan.md", conversation: nil).refusal
    assert_equal @workspace, anchor("workspace/notes.md", conversation: nil).lockable
    assert_equal @human, anchor("user/notes.md", conversation: nil).lockable
  end

  test "a system principal has no Human memory" do
    assert_nil users(:system).controlling_human
    assert_equal :memory_scope_unavailable,
      anchor("user/notes.md", principal: users(:system), agent: users(:system)).refusal
  end

  test "an Agent never resolves user memory through its steward" do
    other = users(:member)
    foreign_agent = other.create_agent(display_name: "Other's Agent")
    assert_equal other, foreign_agent.controlling_human
    assert_equal :memory_scope_unavailable,
      anchor("user/notes.md", principal: foreign_agent, agent: foreign_agent).refusal
    assert_equal foreign_agent, anchor("agent/notes.md", principal: foreign_agent, agent: foreign_agent).lockable

    resolved = anchor("user/notes.md", principal: other, agent: foreign_agent)
    assert_predicate resolved, :resolved?
    assert_equal other, resolved.lockable
    assert_not_equal @human, resolved.lockable
  end

  test "bare paths are invalid and a root absent from the selection is unavailable" do
    assert_equal :memory_path_invalid, anchor("notes.md").refusal
    assert_equal :memory_scope_unavailable, anchor("elsewhere/notes.md").refusal
    assert_equal :memory_path_invalid, anchor("user/").refusal
    assert_equal [nil, nil], Scopes::Anchor.split("notes.md")
    assert_equal %w[user notes.md], Scopes::Anchor.split("user/notes.md")
  end

  test "a deleted default is unavailable and resolution cannot allocate a replacement" do
    collection = memory_collections(:owner)
    assert_predicate collection.tombstone, :accepted?
    assert_no_difference "MemoryCollection.count" do
      assert_equal :memory_scope_unavailable, anchor("user/notes.md").refusal
      assert_equal :memory_scope_unavailable, context.selection_refusal
    end
    assert_equal collection, @human.memory_collections.find_by!(is_default: true)
  end
end
