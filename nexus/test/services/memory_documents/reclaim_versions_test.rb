require "test_helper"

class MemoryDocuments::ReclaimVersionsTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    @user = users(:member)
    @workspace = workspaces(:shared)
  end

  test "referenced versions consume the source budget before a later orphan" do
    kept = bound_versions(2)
    orphan = MemoryDocumentVersion.create!(account: @account, content: "cascade residue")

    first = MemoryDocuments::ReclaimVersions.call(batch: 2)

    assert_equal 2, first[:scanned]
    assert_equal 0, first[:reclaimed]
    assert_equal kept.last, first.cursor
    assert_predicate first, :more?
    assert MemoryDocumentVersion.exists?(orphan.id), "the later orphan belongs to the next source window"

    last = MemoryDocuments::ReclaimVersions.call(batch: 2, after_id: first.cursor)
    assert_equal 1, last[:scanned]
    assert_equal 1, last[:reclaimed]
    assert_equal orphan.id, last.cursor
    assert_not_predicate last, :more?
    assert_not MemoryDocumentVersion.exists?(orphan.id)
    assert_equal kept, MemoryDocumentVersion.order(:id).pluck(:id)
  end

  test "a full referenced final page finishes at an empty continuation and is revisited next wake" do
    kept = bound_versions(2)
    first = MemoryDocuments::ReclaimVersions.call(batch: 2)
    assert_equal [2, 0, true], [first[:scanned], first[:reclaimed], first.more?]

    last = MemoryDocuments::ReclaimVersions.call(batch: 2, after_id: first.cursor)
    assert_equal [0, 0, false], [last[:scanned], last[:reclaimed], last.more?]
    assert_equal kept.last, last.cursor

    MemoryDocument.where(memory_document_version_id: kept).delete_all
    next_wake = MemoryDocuments::ReclaimVersions.call(batch: 2)
    assert_equal 2, next_wake[:reclaimed], "a later cascade is found when the recurring floor restarts"
  end

  test "the job carries a full retained source cursor and parks a partial page" do
    full = Sweeps::Pass.new(counts: { scanned: 1_000, reclaimed: 0 }, cursor: 123, more: true)
    MemoryDocuments::ReclaimVersions.stub(:call, full) do
      assert_enqueued_jobs 1, only: MemoryDocuments::ReclaimVersionsJob do
        assert_enqueued_with(job: MemoryDocuments::ReclaimVersionsJob, args: [123]) do
          MemoryDocuments::ReclaimVersionsJob.perform_now
        end
      end
    end

    call = ->(after_id:, **) do
      assert_equal 123, after_id
      Sweeps::Pass.new(counts: { scanned: 1, reclaimed: 0 }, cursor: 124, more: false)
    end
    MemoryDocuments::ReclaimVersions.stub(:call, call) do
      assert_no_enqueued_jobs(only: MemoryDocuments::ReclaimVersionsJob) do
        MemoryDocuments::ReclaimVersionsJob.perform_now(123)
      end
    end
  end

  test "the production source and reference check stay bounded above referenced history" do
    ids = bound_versions(8_000)
    ApplicationRecord.lease_connection.execute("ANALYZE memory_document_versions, memory_documents")
    results = []
    queries = capture_queries do
      results << MemoryDocuments::ReclaimVersions.call
      results << MemoryDocuments::ReclaimVersions.call(after_id: results.first.cursor)
    end
    assert_equal 2, queries.fetch(:sources).length
    queries.fetch(:sources).each { |source| assert_source_plan(explain(source), rows: 1_000) }
    results.each_with_index do |result, index|
      assert_equal [1_000, 0, ids[(index + 1) * 1_000 - 1], true],
        [result[:scanned], result[:reclaimed], result.cursor, result.more?]
    end

    # Every version is referenced, so replaying this exact guarded DELETE
    # for its execution plan has no effects and tests its retained-history cost.
    assert_equal 2, queries.fetch(:deletes).length
    queries.fetch(:deletes).each do |deletion|
      delete_plan = explain(deletion)
      assert_no_match(/Seq Scan on memory_document_versions|Seq Scan on memory_documents|Hash Anti Join/, delete_plan,
        "the applying statement must not restart a full version or pointer scan")
      assert_match(/Index(?: Only)? Scan using index_memory_documents_on_memory_document_version_id/, delete_plan)
    end
    assert_equal 8_000, MemoryDocumentVersion.count

    empty = capture_queries do
      result = MemoryDocuments::ReclaimVersions.call(after_id: ids.last)
      assert_equal [0, 0, ids.last, false],
        [result[:scanned], result[:reclaimed], result.cursor, result.more?]
    end
    assert_source_plan(explain(empty.fetch(:sources).sole), rows: 0)
  end

  private

    def bound_versions(count)
      now = Time.current
      # Sixty-four pointers per host is the ordinary memory capacity. Bulk
      # setup isolates the recurring query from the cost of authoring them.
      conversation_ids = Conversation.insert_all!(Array.new((count + 63) / 64) do
        { account_id: @account.id, workspace_id: @workspace.id,
          creating_user_id: @user.id, answering_user_id: @user.id,
          last_activity_at: now, created_at: now, updated_at: now }
      end, returning: %w[id]).rows.flatten
      version_ids = MemoryDocumentVersion.insert_all!(Array.new(count) do
        { account_id: @account.id, content: "retained memory", created_at: now }
      end, returning: %w[id]).rows.flatten
      MemoryDocument.insert_all!(version_ids.each_with_index.map do |version_id, index|
        { account_id: @account.id, conversation_id: conversation_ids[index / 64],
          name: "note-#{index % 64}.md", memory_document_version_id: version_id,
          created_at: now, updated_at: now }
      end)
      version_ids
    end

    def explain(source)
      sql, binds = source
      ApplicationRecord.lease_connection.select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}",
        "EXPLAIN", binds).join("\n")
    end

    def capture_queries
      queries = { sources: [], deletes: [] }
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:cached]

        sql = payload[:sql]
        if sql.start_with?('SELECT "memory_document_versions"."id"')
          queries.fetch(:sources) << [sql.dup, payload.fetch(:binds).dup]
        elsif sql.start_with?('DELETE FROM "memory_document_versions"')
          queries.fetch(:deletes) << [sql.dup, payload.fetch(:binds).dup]
        end
      end
      begin
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      queries
    end

    def assert_source_plan(plan, rows:)
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using memory_document_versions_pkey/, plan)
      assert_no_match(/Join|SubPlan|Seq Scan|Bitmap|Sort|Filter:/, plan,
        "references must be checked only after a bounded version window is materialized")
      assert_match(/actual [^\n]*rows=#{rows}(?:\.0+)? loops=1/, plan)
    end
end
