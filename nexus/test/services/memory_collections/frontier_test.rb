require "test_helper"

class MemoryCollectionFrontierTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:agent)
  end

  test "empty tombstones consume the indexed source window without hiding a later nonempty collection" do
    now = Time.current
    base = { account_id: @account.id, workspace_id: @workspace.id, created_at: now, updated_at: now }
    MemoryCollection.insert_all!(Array.new(8_000) { base })
    stamp = 1.hour.ago
    retained = MemoryCollection.insert_all!(Array.new(1_000) { base.merge(deleted_at: stamp) }, returning: %w[id]).rows.flatten
    tail = @workspace.memory_collections.create!(name: "Tail")
    version = MemoryDocumentVersion.create!(account: @account, content: "to purge")
    document = tail.memory_documents.create!(name: "note.md", memory_document_version: version)
    tail.update!(deleted_at: stamp)
    ApplicationRecord.lease_connection.execute("ANALYZE memory_collections")

    first = nil
    sql = capture_source('SELECT "memory_collections".*') { first = MemoryCollections::Purge.call(batch: 200) }
    assert_window(explain(sql), index: "memory_collections_purge_frontier", rows: 200)
    assert_equal [200, 0, true], [first[:scanned], first[:processed], first.more?]
    assert_equal [stamp.iso8601(6), retained[199]], first.cursor
    assert MemoryDocument.exists?(document.id)

    second = nil
    sql = capture_source('SELECT "memory_collections".*') do
      second = MemoryCollections::Purge.call(batch: 200,
        after_deleted_at: first.cursor.first, after_id: first.cursor.last)
    end
    assert_window(explain(sql), index: "memory_collections_purge_frontier", rows: 200)
    assert_equal [stamp.iso8601(6), retained[399]], second.cursor
    assert_equal [200, 0, true], [second[:scanned], second[:processed], second.more?]
  end

  test "owner collection and document windows use their ordered indexes before mutation" do
    now = Time.current
    base = { account_id: @account.id, created_at: now, updated_at: now }
    MemoryCollection.insert_all!(Array.new(8_000) { base.merge(workspace_id: @workspace.id) })
    ids = MemoryCollection.insert_all!(Array.new(200) { base.merge(user_id: @user.id) }, returning: %w[id]).rows.flatten
    version = MemoryDocumentVersion.create!(account: @account, content: "retained")
    MemoryDocument.insert_all!(ids.flat_map do |id|
      Array.new(64) do |index|
        base.merge(memory_collection_id: id, memory_document_version_id: version.id, name: "note#{index}.md")
      end
    end)
    ApplicationRecord.lease_connection.execute("ANALYZE memory_collections, memory_documents")

    owner_sql = capture_source('SELECT "memory_collections"."id"') do
      @user.with_lock { assert_equal 20, MemoryCollections::Drain.call(owner: @user, budget: 20) }
    end
    assert_window(explain(owner_sql), index: "index_memory_collections_on_user_id_and_id", rows: 20)

    document_sql = capture_source('SELECT "memory_documents"."id"') do
      @user.with_lock { assert_equal 7, MemoryCollections::Drain.collection(id: ids.last, budget: 7) }
    end
    assert_window(explain(document_sql), index: "index_memory_documents_on_memory_collection_id_and_id", rows: 7)
    assert_equal 57, MemoryDocument.where(memory_collection_id: ids.last).count
    assert MemoryDocumentVersion.exists?(version.id)
  end

  test "fork bounds copied collections and documents before walking retained ordinary tombstones" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:member))
    MemoryCollection.default_for(conversation)
    now = Time.current
    base = { account_id: @account.id, conversation_id: conversation.id, created_at: now, updated_at: now }
    MemoryCollection.insert_all!(Array.new(9_000) { base.merge(deleted_at: now) })
    ids = MemoryCollection.insert_all!(Array.new(8_000) { base }, returning: %w[id]).rows.flatten
    version = MemoryDocumentVersion.create!(account: @account, content: "copy budget")
    MemoryDocument.insert_all!(ids.first(200).flat_map do |id|
      Array.new(64) do |index|
        { account_id: @account.id, memory_collection_id: id, memory_document_version_id: version.id,
          name: "note#{index}.md", created_at: now, updated_at: now }
      end
    end)
    ApplicationRecord.lease_connection.execute("ANALYZE memory_collections, memory_documents")

    document_sql = nil
    collection_sql = capture_source('SELECT "memory_collections"."id"') do
      document_sql = capture_source('SELECT "memory_documents"."id"') do
        result = Conversations::Fork.call(Conversations::Fork::Command.new(conversation: conversation,
          turn_public_id: nil, variant_public_id: nil, acting_user: users(:member), title: nil, side: true))
        assert_equal :fork_too_large, result.outcome
      end
    end
    assert_window(explain(collection_sql), index: "memory_collections_fork_frontier", rows: 5001)
    assert_window(explain(document_sql), index: "index_memory_documents_on_memory_collection_id_and_id", rows: 5001)
  end

  private

    def capture_source(prefix)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:cached] || !payload[:sql].start_with?(prefix)
        next unless payload[:sql].include?("LIMIT") && payload[:sql].include?("ORDER BY")

        queries << [payload[:sql].dup, payload.fetch(:binds).dup]
      end
      begin
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      queries.sole
    end

    def explain(source)
      sql, binds = source
      ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
    end

    def assert_window(plan, index:, rows:)
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using #{index}/, plan)
      assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Filter:/, plan)
      assert_match(/actual [^\n]*rows=#{rows}(?:\.0+)? loops=1/, plan)
    end
end
