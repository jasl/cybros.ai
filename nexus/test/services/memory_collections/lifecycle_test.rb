require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class MemoryCollectionLifecycleTest < ActiveJob::TestCase
  include LockOrderTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
  end

  test "founding creates system and human defaults in the same transaction" do
    Account.destroy_all
    account = Account.create_with_owner(account: { name: "Memory birth" }, owner: {
      email: "birth@example.com", display_name: "Owner", password: "correct horse battery",
      password_confirmation: "correct horse battery",
    })
    assert_equal 2, account.users.count
    assert_equal 2, account.memory_collections.count
    account.users.each { |user| assert_default(user) }
    account.destroy!
    assert_empty MemoryCollection.all
  end

  test "direct members invitations and device pairing each create one default" do
    direct = @account.create_direct_member(display_name: "Direct", email: "direct@example.com", role: "member",
      password: "correct horse battery", password_confirmation: "correct horse battery")
    assert_equal :created, direct.outcome
    assert_default(direct.member)
    invitation = @account.invitations.create!(inviter: users(:owner), email: "invited@example.com")
    accepted = invitation.accept(display_name: "Invited", password: "correct horse battery",
      password_confirmation: "correct horse battery")
    assert_equal :accepted, accepted.outcome
    assert_default(accepted.member)

    paired = connect_agent_session(steward: @human, agent_identifier: "memory-birth-agent")
    assert_equal :minted, paired.outcome
    agent = @account.users.find_by!(agent_identifier: "memory-birth-agent")
    first = assert_default(agent)
    first.tombstone
    connect_agent_session(steward: @human, agent_identifier: "memory-birth-agent")
    assert_equal first.public_id, assert_default(agent).public_id
    assert_predicate first.reload, :deleted?
  end

  test "named declaration replacement and remove restore keep default identity and documents" do
    configuration = { tool_definitions: [], approval_mode: nil, approval_rules: nil,
      prompt_mechanism: "default", prompt_template: nil, compaction_policy: nil }
    result = Users::DeclareNamedAgent.call(caller: @agent, name: "memory-birth", scope: "steward",
      description: "Notes", configuration: configuration)
    assert_predicate result, :accepted?
    agent = result.user
    collection = assert_default(agent)
    document = write(collection)
    assert_equal :removed, agent.remove
    assert_equal "retained", document.reload.content
    assert_equal :restored, agent.restore
    repeated = Users::DeclareNamedAgent.call(caller: @agent, name: "memory-birth", scope: "steward",
      description: "Changed declaration", configuration: configuration)
    assert_predicate repeated, :accepted?
    assert_equal collection.public_id, assert_default(repeated.user).public_id
    assert_equal "retained", document.reload.content
  end

  test "workspace and conversation birth allocate defaults and failure rolls back the owner" do
    workspace = Workspaces::Create.call(creator: @human, name: "Memory room").workspace
    assert_default(workspace)
    conversation = create_conversation(workspace: workspace)
    assert_default(conversation)

    MemoryCollection.stub(:default_for, ->(*) { raise "allocation failed" }) do
      assert_no_difference [-> { Workspace.count }, -> { Conversation.count }, -> { MemoryCollection.count }] do
        assert_raises(RuntimeError) { Workspaces::Create.call(creator: @human, name: "Must roll back") }
        assert_raises(RuntimeError) { create_conversation }
      end
    end
  end

  test "deleted collection purges immediately in bounded repeatable passes without losing its identity" do
    collection = MemoryCollection.default_for(@workspace)
    5.times { |index| write(collection, name: "note#{index}.md") }
    collection.tombstone
    clear_enqueued_jobs
    first = MemoryCollections::Purge.call(batch: 2)
    assert_equal [1, 2, true], [first[:scanned], first[:processed], first.more?]
    assert_equal 3, collection.memory_documents.count
    assert_equal [nil, 0], first.cursor
    second = MemoryCollections::Purge.call(batch: 2, after_deleted_at: first.cursor.first, after_id: first.cursor.last)
    assert_equal 2, second[:processed]
    assert_equal 1, collection.memory_documents.count
    last = MemoryCollections::Purge.call(batch: 2)
    assert_equal [1, 1, false], [last[:scanned], last[:processed], last.more?]
    assert_empty collection.memory_documents
    assert_equal 0, MemoryCollections::Purge.call(batch: 2)[:processed]
    assert_equal collection.public_id, MemoryCollection.default_for(@workspace).public_id
    assert_predicate collection.reload, :deleted?
  end

  test "conversation collection charges document and collection rows before final owner deletion" do
    conversation = create_conversation
    3.times { write(conversation.memory_collections.create!(name: "Notes")) }
    conversation.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
    initial = conversation.memory_collections.count + conversation.memory_documents.count
    assert_equal 7, initial
    totals = []
    4.times do
      result = Conversations::Reap.call(batch: 2).value
      totals << result[:memory_processed]
      assert_operator result[:memory_processed], :<=, 2
      assert_operator result[:scanned], :<=, 2
    end
    assert_equal initial, totals.sum
    refute Conversation.exists?(conversation.id)
    assert_empty MemoryCollection.where(conversation_id: conversation.id)
  end

  test "ancestry retains memory until the same owner can be reaped" do
    conversation = create_conversation
    collection = assert_default(conversation)
    document = write(collection)
    child = Conversations::Fork.call(Conversations::Fork::Command.new(conversation: conversation,
      acting_user: @human, turn_public_id: nil, variant_public_id: nil, title: nil, side: true)).value
    conversation.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
    result = Conversations::Reap.call(batch: 2).value
    assert_equal [0, 0], [result[:reaped], result[:memory_processed]]
    assert_equal "retained", document.reload.content
    assert_predicate Conversations::Tombstone.call(conversation: child), :accepted?
    refute Conversation.exists?(child.id)
    assert_equal 1, Conversations::Reap.call(batch: 2).value[:reaped]
    refute Conversation.exists?(conversation.id)
  end

  test "workspace owner collection shares its budget across all collections and the final owner" do
    workspace = Workspaces::Create.call(creator: @human, name: "Collected room").workspace
    3.times { write(workspace.memory_collections.create!(name: "Notes")) }
    workspace.with_lock do
      workspace.accept_delete
      assert_equal :completed, workspace.complete_transition
      workspace.update!(deleted_at: 31.days.ago)
    end
    total = 0
    4.times do
      pass = Workspaces::Collect.call(budget: 2)
      assert_operator pass[:processed], :<=, 2
      total += pass[:processed]
    end
    assert_equal 8, total
    refute Workspace.exists?(workspace.id)
    assert_empty MemoryCollection.where(workspace_id: workspace.id)
  end

  test "user removal preserves collections and a deliberate physical teardown requires bounded draining" do
    user = create_agent_member(steward: @human)
    3.times { write(user.memory_collections.create!(name: "Private")) }
    assert_equal :removed, user.remove
    assert_equal 3, user.memory_documents.count
    assert_equal :restored, user.restore
    assert_equal 3, user.memory_collections.count
    assert_raises(ActiveRecord::InvalidForeignKey) do
      User.transaction(requires_new: true) { user.destroy! }
    end
    user.reload
    3.times do
      user.with_lock do
        assert_equal 2, MemoryCollections::Drain.call(owner: user, budget: 2)
      end
    end
    user.destroy!
    refute User.exists?(user.id)
  end

  test "resolved document writes recheck removed User and tombstoned Workspace owners" do
    agent_collection = assert_default(@agent)
    agent_document = write(agent_collection)
    agent_anchor = anchor(agent_collection, agent_document.name)
    assert_equal :removed, @agent.remove
    refused = agent_collection.with_mutation do
      MemoryDocuments::Write.call(anchor: agent_anchor, content: "late", expected: nil)
    end
    assert_equal :memory_scope_unavailable, refused.outcome
    assert_equal "retained", agent_document.reload.content

    workspace_collection = assert_default(@workspace)
    document = write(workspace_collection)
    resolved = anchor(workspace_collection, document.name)
    @workspace.with_lock { @workspace.accept_delete }
    refused = workspace_collection.with_mutation do
      MemoryDocuments::Write.call(anchor: resolved, content: "late", expected: nil)
    end
    assert_equal :memory_scope_unavailable, refused.outcome
    assert_equal "retained", document.reload.content
    context = MemoryDocuments::Context.new(workspace: @workspace.reload, conversation: nil,
      principal: @human, configuration: nil, agent: @agent, execution: true)
    assert_empty context.bindings
    assert_empty context.projection.fetch(:bindings)
  end

  test "metadata CAS and per collection document limits do not become an owner total limit" do
    first = @workspace.memory_collections.create!(name: "First")
    stale = MemoryCollection.find(first.id)
    first.update!(name: "Changed")
    assert_raises(ActiveRecord::StaleObjectError) { stale.update!(description: "stale") }
    64.times { |index| write(first, name: "note#{index}.md") }
    anchor = anchor(first, "extra.md")
    first.with_mutation do
      assert_equal :memory_full, MemoryDocuments::Write.call(anchor: anchor, content: "overflow", expected: nil).outcome
    end
    second = @workspace.memory_collections.create!(name: "Second")
    assert_equal "retained", write(second).content
    assert_equal 65, @workspace.memory_documents.count
  end

  private

    def assert_default(owner)
      collection = owner.memory_collections.where(is_default: true, speaker_id: nil).sole
      assert_equal owner, collection.owner
      assert collection.public_id.present?
      collection
    end

    def create_conversation(workspace: @workspace)
      result = Conversations::Create.call(Conversations::Create::Command.new(workspace: workspace,
        creating_user: @human, title: nil, metadata: nil, billing_subject: nil))
      assert_predicate result, :accepted?, result.outcome.to_s
      result.value
    end

    def anchor(collection, name)
      Scopes::Anchor::Result.new(collection: collection, scope: collection.natural_scope.to_s, name: name, refusal: nil)
    end

    def write(collection, name: "note.md")
      collection.with_mutation do
        result = MemoryDocuments::Write.call(anchor: anchor(collection, name), content: "retained", expected: nil)
        assert_predicate result, :written?
        result.document
      end
    end
end
