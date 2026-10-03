require "test_helper"

# Staging is a two-step by construction, so bytes nobody named are the
# ordinary residue of that shape. This reclaims them; the interesting half is
# everything it must NOT reclaim.
class ContentUploads::SweepUnboundJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @user = users(:member)
  end

  def upload(created_at: 2.days.ago)
    record = @account.content_uploads.create!(
      creating_user: @user,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("bytes"), filename: "clip.bin", content_type: "application/octet-stream"
      )
    )
    ContentUpload.where(id: record.id).update_all(created_at: created_at)
    record.reload
  end

  test "an upload nobody named is reclaimed once its grace is spent" do
    stale = upload

    assert_difference "ContentUpload.count", -1 do
      ContentUploads::SweepUnboundJob.perform_now
    end
    assert_not ContentUpload.exists?(stale.id)
  end

  test "an upload still inside its grace is left alone" do
    fresh = upload(created_at: 1.hour.ago)

    assert_no_difference "ContentUpload.count" do
      ContentUploads::SweepUnboundJob.perform_now
    end
    assert ContentUpload.exists?(fresh.id)
  end

  # THE ONE THAT MATTERS. A bound upload is somebody's input, and age says
  # nothing about that.
  test "a bound upload is never reclaimed, however old" do
    bound = upload(created_at: 30.days.ago)
    bind(bound)

    assert_no_difference "ContentUpload.count" do
      ContentUploads::SweepUnboundJob.perform_now
    end
    assert ContentUpload.exists?(bound.id)
  end

  # Destroying the row is the whole reclamation: Active Storage's own `dependent::purge_later` takes
  # the bytes with it, so nothing waits on the unattached sweep behind this one.
  test "reclaiming a row takes its bytes with it" do
    stale = upload
    blob_id = stale.file.blob.id

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      ContentUploads::SweepUnboundJob.perform_now
    end

    assert_not ActiveStorage::Blob.exists?(blob_id)
  end

  test "the source window is bounded before bound uploads are filtered" do
    source_time = 4.days.ago.change(usec: 0)
    bound = 2.times.map { bind(upload(created_at: source_time)) }
    orphan = upload(created_at: 3.days.ago)

    first = ContentUpload.reap(batch: 2)

    assert_equal [2, 0, true], [first[:scanned], first[:reaped], first.more?]
    assert_equal bound.last.id, first.cursor.last
    assert ContentUpload.where(id: bound.map(&:id)).exists?
    assert ContentUpload.exists?(orphan.id)

    second = ContentUpload.reap(
      batch: 2, after_created_at: first.cursor.first, after_id: first.cursor.last
    )

    assert_equal [1, 1, false], [second[:scanned], second[:reaped], second.more?]
    assert_not ContentUpload.exists?(orphan.id)
  end

  test "a full source window enqueues one bounded continuation" do
    cursor_created_at = 2.days.ago.iso8601(6)
    result = Sweeps::Pass.new(
      counts: { scanned: ContentUpload::REAP_BATCH_SIZE, reaped: 0 }, cursor: [cursor_created_at, 42], more: true
    )
    reap = lambda do |batch:, after_created_at:, after_id:|
      assert_equal ContentUpload::REAP_BATCH_SIZE, batch
      assert_nil after_created_at
      assert_equal 0, after_id
      result
    end

    ContentUpload.stub(:reap, reap) do
      assert_enqueued_with(
        job: ContentUploads::SweepUnboundJob, args: [cursor_created_at, 42]
      ) do
        ContentUploads::SweepUnboundJob.perform_now
      end
    end
  end

  test "the source scan has a matching continuation index" do
    index = ContentUpload.connection.indexes(:content_uploads).find do |candidate|
      candidate.name == "index_content_uploads_on_created_at_and_id"
    end

    assert index
    assert_equal %w[created_at id], index.columns
  end

  test "the reference check stays inside the source window at scale" do
    seed_bound_history(count: 8_000)
    ApplicationRecord.lease_connection.execute(
      "ANALYZE content_uploads, content_body_uploads"
    )

    source_scan = nil
    reference_scan = nil
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      if sql.start_with?(
        'SELECT "content_uploads"."id", "content_uploads"."created_at"'
      )
        source_scan ||= [sql.dup, payload.fetch(:binds).dup]
      elsif sql.start_with?('SELECT "content_uploads".*') &&
          sql.include?("content_body_uploads.content_upload_id = content_uploads.id")
        reference_scan ||= [sql.dup, payload.fetch(:binds).dup]
      end
    end

    begin
      result = ContentUpload.reap
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal [500, 0, true], [result[:scanned], result[:reaped], result.more?]
    assert source_scan, "the public reaper must execute its bounded source scan"
    assert reference_scan, "the public reaper must execute its reference check"

    source_plan = explain(*source_scan)
    reference_plan = explain(*reference_scan)

    assert_match(
      /Index(?: Only)? Scan using index_content_uploads_on_created_at_and_id/,
      source_plan
    )
    assert_match(/\ALimit\s/, source_plan)
    assert_no_match(/(?:Bitmap|Seq) Scan on content_uploads(?:\s|$)/, source_plan)
    assert_no_match(/Sort/, source_plan)
    assert_no_match(/Filter:/, source_plan)
    assert_match(/SubPlan/, reference_plan)
    assert_match(
      /Index(?: Only)? Scan using index_content_body_uploads_on_content_upload_id/,
      reference_plan
    )
    assert_no_match(/Seq Scan on content_uploads(?:\s|$)/, reference_plan)
    assert_no_match(/Seq Scan on content_body_uploads(?:\s|$)/, reference_plan)
    assert_no_match(/Hash Anti Join/, reference_plan)
  end

  private

    def bind(record)
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @user,
        workload: "transcription"
      )
      body = ContentBody.create!(one_shot: one_shot, role: "input")
      ContentBodyUpload.create!(content_body: body, content_upload: record)
      record
    end

    def seed_bound_history(count:)
      one_shot = OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: @user,
        workload: "transcription"
      )
      body = ContentBody.create!(one_shot: one_shot, role: "input")
      created_at = 10.days.ago.change(usec: 0)
      rows = Array.new(count) do
        {
          account_id: @account.id,
          creating_user_id: @user.id,
          created_at: created_at,
          updated_at: created_at,
        }
      end
      upload_ids = ContentUpload.insert_all!(rows, returning: %w[id]).rows.flatten
      ContentBodyUpload.insert_all!(
        upload_ids.map do |upload_id|
          { content_body_id: body.id, content_upload_id: upload_id }
        end
      )
    end

    def explain(sql, binds)
      ApplicationRecord.lease_connection
        .select_values("EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds).join("\n")
    end
end
