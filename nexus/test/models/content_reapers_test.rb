require "test_helper"

# The age-gated content cleanup primitives. Fragments are reference-counted by existence, so
# collection strands them and this reaper collects the strays after their grace. The adopt-vs-reap
# race is settled in the reaper's disfavor by design: a concurrent adoption never loses, and the
# restrictive FK is the backstop that makes that true.
class ContentReapersTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  def fragment(payload = { "text" => SecureRandom.hex(4) }, created_at: Time.current)
    address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
    @account.content_fragments.create!(
      payload: payload, digest: address.digest
    ).tap do |record|
      ContentFragment.where(id: record.id).update_all(created_at: created_at)
    end
  end

  def bound_fragment(created_at:)
    inference_request = create_inference_request
    payload = { "text" => "bound-#{SecureRandom.hex(4)}" }
    ContentBodies::Replace.call(owner: inference_request, role: "input", entries: [payload])
    address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
    ContentFragment.find_by!(account: @account, digest: address.digest).tap do |record|
      ContentFragment.where(id: record.id).update_all(created_at: created_at)
    end
  end

  test "an orphan past its grace is collected" do
    stale = fragment(created_at: 2.days.ago)

    result = ContentFragment.reap

    assert_equal 1, result[:scanned]
    assert_equal 1, result[:reaped]
    assert_not result.more?
    assert_not ContentFragment.exists?(id: stale.id)
  end

  # The grace is what makes adopt-vs-reap safe: a fragment the writer just
  # created, and has not yet referenced, must survive long enough to be
  # adopted by the body being built.
  test "a fresh orphan is inside its grace and survives" do
    fresh = fragment

    result = ContentFragment.reap

    assert_equal 0, result[:scanned]
    assert_equal 0, result[:reaped]
    assert_not result.more?
    assert ContentFragment.exists?(id: fresh.id)
  end

  # Reference-counted by existence: one surviving entry keeps it, however old.
  test "a referenced fragment is never collected however old it is" do
    referenced = bound_fragment(created_at: 30.days.ago)

    result = ContentFragment.reap

    assert_equal 1, result[:scanned]
    assert_equal 0, result[:reaped]
    assert_not result.more?
    assert ContentFragment.exists?(id: referenced.id)
  end

  # Collection strands fragments (M6 stage B); this is the other half of that
  # contract — what strands them is not what deletes them.
  test "a fragment stranded by collection is collected once it ages out" do
    stranded = bound_fragment(created_at: 2.days.ago)
    ContentBodyEntry.where(content_fragment_id: stranded.id).delete_all

    result = ContentFragment.reap

    assert_equal 1, result[:scanned]
    assert_equal 1, result[:reaped]
    assert_not result.more?
    assert_not ContentFragment.exists?(id: stranded.id)
  end

  test "the fragment reap is bounded and restartable" do
    3.times { fragment(created_at: 2.days.ago) }

    first = ContentFragment.reap(batch: 2)
    second = ContentFragment.reap(
      batch: 2, after_created_at: first.cursor.first, after_id: first.cursor.last
    )
    third = ContentFragment.reap(
      batch: 2, after_created_at: second.cursor.first, after_id: second.cursor.last
    )

    assert_equal [2, 2, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal [1, 1, false], [second[:scanned], second[:reaped], second.more?]
    assert_equal [0, 0, false], [third[:scanned], third[:reaped], third.more?]
  end

  test "the fragment scan bounds source rows before filtering references" do
    referenced_at = 4.days.ago.change(usec: 0)
    referenced = 2.times.map { bound_fragment(created_at: referenced_at) }
    orphan = fragment(created_at: 3.days.ago)

    first = ContentFragment.reap(batch: 2)

    assert_equal [2, 0, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal referenced.last.id, first.cursor.last
    assert_equal referenced_at.iso8601(6), first.cursor.first
    assert ContentFragment.where(id: referenced.map(&:id)).exists?
    assert ContentFragment.exists?(id: orphan.id)

    second = ContentFragment.reap(
      batch: 2, after_created_at: first.cursor.first, after_id: first.cursor.last
    )

    assert_equal [1, 1, false], [second[:scanned], second[:reaped], second.more?]
    assert_not ContentFragment.exists?(id: orphan.id)
  end

  test "a new recurring pass revisits a referenced row advanced past by a cursor" do
    referenced = bound_fragment(created_at: 4.days.ago)
    tail = fragment(created_at: 3.days.ago)

    first = ContentFragment.reap(batch: 1)
    ContentBodyEntry.where(content_fragment_id: referenced.id).delete_all
    continuation = ContentFragment.reap(
      batch: 1, after_created_at: first.cursor.first, after_id: first.cursor.last
    )

    assert_equal [1, 0, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal [1, 1, true],
      [continuation[:scanned], continuation[:reaped], continuation.more?]
    assert ContentFragment.exists?(id: referenced.id),
      "a continuation never rewinds behind its cursor"
    assert_not ContentFragment.exists?(id: tail.id)

    recurring = ContentFragment.reap(batch: 1)

    assert_equal [1, 1, true], [recurring[:scanned], recurring[:reaped], recurring.more?]
    assert_not ContentFragment.exists?(id: referenced.id),
      "the next level-triggered run starts without a cursor and revisits blockers"
  end

  test "the fragment source scan has a matching continuation index" do
    index = ContentFragment.connection.indexes(:content_fragments).find do |candidate|
      candidate.name == "index_content_fragments_on_created_at_and_id"
    end

    assert index
    assert_equal %w[created_at id], index.columns
  end

  test "the fragment reference check stays inside the source window at scale" do
    seed_referenced_fragment_history(count: 8_000)
    ApplicationRecord.lease_connection.execute(
      "ANALYZE content_fragments, content_body_entries"
    )

    source_scan = nil
    reference_scan = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      if sql.start_with?(
        'SELECT "content_fragments"."id", "content_fragments"."created_at"'
      )
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      elsif sql.start_with?('SELECT "content_fragments"."id"') &&
          sql.include?("content_body_entries.content_fragment_id = content_fragments.id")
        reference_scan ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end

    begin
      result = ContentFragment.reap(batch: 1_000)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal [1_000, 0, true], [result[:scanned], result[:reaped], result.more?]
    assert source_scan, "the public reaper must execute its bounded source scan"
    assert reference_scan, "the public reaper must execute its reference check"

    source_plan = explain(*source_scan)
    reference_plan = explain(*reference_scan)

    assert_match(
      /Index(?: Only)? Scan using index_content_fragments_on_created_at_and_id/,
      source_plan
    )
    assert_match(/SubPlan/, reference_plan)
    assert_match(
      /Index(?: Only)? Scan using index_content_body_entries_on_content_fragment_id/,
      reference_plan
    )
    assert_no_match(/Seq Scan on content_body_entries(?:\s|$)/, reference_plan)
    assert_no_match(/Hash Anti Join/, reference_plan)
  end

  # The FK backstop — an adoption that commits between the candidate scan and
  # the DELETE — lives in test/models/content_fragment_reap_race_test.rb. It
  # cannot be written here: a transactional test can only create the entry
  # before the scan, which makes the fragment a non-candidate and issues no
  # DELETE at all. A test of that shape stood here and passed while the
  # backstop it was named for was unreachable dead code.

  test "an expired create receipt is reaped for storage only" do
    inference_request = create_inference_request
    receipt = InferenceRequestCreateReceipt.create!(
      inference_request: inference_request, idempotency_key: SecureRandom.uuid,
      request_digest: SecureRandom.hex(32)
    )
    InferenceRequestCreateReceipt.where(id: receipt.id).update_all(created_at: 25.hours.ago)

    assert_equal 1, InferenceRequestCreateReceipt.reap

    assert_not InferenceRequestCreateReceipt.exists?(id: receipt.id)
    assert InferenceRequest.exists?(id: inference_request.id),
      "reaping replay evidence never touches the work it pointed at"
  end

  test "create receipt reap is bounded and restartable" do
    inference_requests = 2.times.map { create_inference_request }
    receipts = inference_requests.map do |inference_request|
      InferenceRequestCreateReceipt.create!(
        inference_request: inference_request, idempotency_key: SecureRandom.uuid,
        request_digest: SecureRandom.hex(32)
      )
    end
    InferenceRequestCreateReceipt.where(id: receipts.map(&:id)).update_all(created_at: 25.hours.ago)

    assert_equal 1, InferenceRequestCreateReceipt.reap(batch: 1)
    assert_equal 1, InferenceRequestCreateReceipt.where(id: receipts.map(&:id)).count
    assert_equal 1, InferenceRequestCreateReceipt.reap(batch: 1)
    assert_equal 0, InferenceRequestCreateReceipt.where(id: receipts.map(&:id)).count
    assert_equal 0, InferenceRequestCreateReceipt.reap(batch: 1)
    assert_equal 2, InferenceRequest.where(id: inference_requests.map(&:id)).count,
      "bounded receipt cleanup never collects the work it pointed at"
  end

  test "create receipt reap starts with the oldest expired acceptance" do
    newer, older = 2.times.map do
      inference_request = create_inference_request
      InferenceRequestCreateReceipt.create!(
        inference_request: inference_request, idempotency_key: SecureRandom.uuid,
        request_digest: SecureRandom.hex(32)
      )
    end
    InferenceRequestCreateReceipt.where(id: newer.id).update_all(created_at: 25.hours.ago)
    InferenceRequestCreateReceipt.where(id: older.id).update_all(created_at: 26.hours.ago)

    assert_equal 1, InferenceRequestCreateReceipt.reap(batch: 1)

    assert InferenceRequestCreateReceipt.exists?(newer.id)
    assert_not InferenceRequestCreateReceipt.exists?(older.id),
      "the index-ordered source window starts with the oldest acceptance"
  end

  test "the create-receipt expiry scan has a matching continuation index" do
    index = InferenceRequestCreateReceipt.connection
      .indexes(:inference_request_create_receipts)
      .find { |candidate| candidate.name == "index_inference_request_create_receipts_on_created_at_and_id" }

    assert index
    assert_equal %w[created_at id], index.columns
  end

  test "create-receipt reap materializes its bounded ids before deletion" do
    inference_request = create_inference_request
    receipt = InferenceRequestCreateReceipt.create!(
      inference_request: inference_request, idempotency_key: SecureRandom.uuid,
      request_digest: SecureRandom.hex(32)
    )
    InferenceRequestCreateReceipt.where(id: receipt.id).update_all(created_at: 25.hours.ago)

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      if sql.match?(/\A(?:SELECT|DELETE).*inference_request_create_receipts/)
        statements << sql
      end
    end
    begin
      assert_equal 1, InferenceRequestCreateReceipt.reap(batch: 1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 2, statements.length
    assert statements.first.start_with?('SELECT "inference_request_create_receipts"."id"')
    assert statements.second.start_with?('DELETE FROM "inference_request_create_receipts"')
    assert_no_match(/SELECT.+FROM "inference_request_create_receipts"/, statements.second)
  end

  test "the storage reapers are wired through shallow recurring jobs" do
    production = recurring_schedule

    assert_equal "ContentFragments::ReapJob",
      production.dig("reap_content_fragments", "class")
    assert_equal "every day at 4:30am",
      production.dig("reap_content_fragments", "schedule")
    assert_equal "InferenceRequestCreateReceipts::ReapJob",
      production.dig("reap_inference_request_create_receipts", "class")
    assert_equal "every hour at minute 40",
      production.dig("reap_inference_request_create_receipts", "schedule")
    assert_equal "ConversationCommandReceipts::ReapJob",
      production.dig("reap_conversation_command_receipts", "class")
    assert_equal "every hour at minute 45",
      production.dig("reap_conversation_command_receipts", "schedule")
  end

  test "a live create receipt is left alone" do
    inference_request = create_inference_request
    InferenceRequestCreateReceipt.create!(
      inference_request: inference_request, idempotency_key: SecureRandom.uuid,
      request_digest: SecureRandom.hex(32)
    )

    assert_equal 0, InferenceRequestCreateReceipt.reap
  end

  private

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN #{sql}", "EXPLAIN", binds).join("\n")
    end

    def create_inference_request
      InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
    end

    def seed_referenced_fragment_history(count:)
      body = ContentBody.create!(
        inference_request: create_inference_request, role: "input"
      )
      created_at = 10.days.ago.change(usec: 0)
      prefix = SecureRandom.hex(8)
      fragments = Array.new(count) do |index|
        payload = { "reap_plan_probe" => "#{prefix}-#{index}" }
        address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
        {
          account_id: @account.id, digest: address.digest, payload: payload,
          created_at: created_at, updated_at: created_at,
        }
      end
      fragment_ids = ContentFragment.insert_all!(
        fragments, returning: %w[id]
      ).rows.flatten

      ContentBodyEntry.insert_all!(
        fragment_ids.map.with_index do |fragment_id, position|
          {
            account_id: @account.id, content_body_id: body.id,
            content_fragment_id: fragment_id, position: position,
            created_at: created_at, updated_at: created_at,
          }
        end
      )
    end
end
