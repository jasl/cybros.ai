require "test_helper"

# The unattached-blob sweep: what reclaims a blob whose attach never came.
#
# Terminal apply stages output blobs BEFORE its transaction — deliberately,
# so object-storage IO never rides the invocation lock — which opens a crash
# window where a blob row exists and nothing owns it. Reference counting
# cannot see it (purging hangs off record destroy, and there is no record),
# so the predecessor ran this sweep and so does this.
class ActiveStorageMaintenance::SweepUnattachedBlobsJobTest < ActiveJob::TestCase
  test "an old unattached blob is purged and everything owned or fresh survives" do
    orphan = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("stranded"), filename: "stranded.bin"
    )
    orphan.update_column(:created_at, 3.days.ago)

    fresh = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("staging"), filename: "staging.bin"
    )

    owned_bytes = "owned-output"
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    one_shot = OneShot.create!(
      account: account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    invocation.output_files.attach(
      io: StringIO.new(owned_bytes), filename: "owned.png", content_type: "image/png"
    )
    owned = invocation.output_files.sole.blob
    owned.update_column(:created_at, 3.days.ago)

    perform_enqueued_jobs do
      ActiveStorageMaintenance::SweepUnattachedBlobsJob.perform_now
    end

    assert_not ActiveStorage::Blob.exists?(orphan.id), "old and unowned is exactly the target"
    assert ActiveStorage::Blob.exists?(fresh.id),
      "the grace period is what makes the ordinary stage-then-attach window safe"
    assert ActiveStorage::Blob.exists?(owned.id), "an attached blob is never the sweep's business"
  end
end
