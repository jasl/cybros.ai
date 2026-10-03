require "test_helper"

# These recurring shells remain level-triggered and bounded: a partial pass
# sleeps until the next recurring wake, while a full window schedules exactly
# one immediate continuation.
class ModelWorkReapersTest < ActiveJob::TestCase
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    @account = accounts(:cybros)
  end

  test "idle reaper jobs enqueue no continuation" do
    assert_no_enqueued_jobs(only: ContentFragments::ReapJob) do
      ContentFragments::ReapJob.perform_now
    end
    assert_no_enqueued_jobs(only: OneShotCreateReceipts::ReapJob) do
      OneShotCreateReceipts::ReapJob.perform_now
    end
    assert_no_enqueued_jobs(only: OneShots::ReapJob) do
      OneShots::ReapJob.perform_now
    end
  end

  test "a partial fragment window reaps its candidates without continuing" do
    fragment = stale_fragment

    stub_const(ContentFragments::ReapJob, :BATCH, 2) do
      assert_no_enqueued_jobs(only: ContentFragments::ReapJob) do
        ContentFragments::ReapJob.perform_now
      end
    end

    assert_not ContentFragment.exists?(fragment.id)
  end

  test "a full fragment window enqueues exactly one continuation" do
    fragment = stale_fragment
    fragment.reload

    stub_const(ContentFragments::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: ContentFragments::ReapJob do
        assert_enqueued_with(
          job: ContentFragments::ReapJob,
          args: [fragment.created_at.iso8601(6), fragment.id]
        ) do
          ContentFragments::ReapJob.perform_now
        end
      end
    end

    assert_not ContentFragment.exists?(fragment.id)
  end

  test "a full scanned fragment window continues once after a lost delete" do
    cursor_created_at = 2.days.ago.iso8601(6)
    result = Sweeps::Pass.new(counts: { scanned: 2, reaped: 0 }, cursor: [cursor_created_at, 42], more: true)

    reap = lambda do |batch:, after_created_at:, after_id:|
      assert_equal 2, batch
      assert_nil after_created_at
      assert_equal 0, after_id
      result
    end

    ContentFragment.stub(:reap, reap) do
      stub_const(ContentFragments::ReapJob, :BATCH, 2) do
        assert_enqueued_jobs 1, only: ContentFragments::ReapJob do
          assert_enqueued_with(
            job: ContentFragments::ReapJob, args: [cursor_created_at, 42]
          ) do
            ContentFragments::ReapJob.perform_now
          end
        end
      end
    end
  end

  test "a partial create-receipt batch reaps its rows without continuing" do
    one_shot, receipt = expired_receipt

    stub_const(OneShotCreateReceipts::ReapJob, :BATCH, 2) do
      assert_no_enqueued_jobs(only: OneShotCreateReceipts::ReapJob) do
        OneShotCreateReceipts::ReapJob.perform_now
      end
    end

    assert_not OneShotCreateReceipt.exists?(receipt.id)
    assert OneShot.exists?(one_shot.id), "receipt cleanup must not collect accepted work"
  end

  test "a full create-receipt batch enqueues exactly one continuation" do
    one_shot, receipt = expired_receipt

    stub_const(OneShotCreateReceipts::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: OneShotCreateReceipts::ReapJob do
        assert_enqueued_with(job: OneShotCreateReceipts::ReapJob, args: []) do
          OneShotCreateReceipts::ReapJob.perform_now
        end
      end
    end

    assert_not OneShotCreateReceipt.exists?(receipt.id)
    assert OneShot.exists?(one_shot.id), "receipt cleanup must not collect accepted work"
  end

  test "a partial OneShot window reaps its tombstones without continuing" do
    one_shot = aged_tombstone

    stub_const(OneShots::ReapJob, :BATCH, 2) do
      assert_no_enqueued_jobs(only: OneShots::ReapJob) do
        OneShots::ReapJob.perform_now
      end
    end

    assert_not OneShot.exists?(one_shot.id)
  end

  test "a full OneShot window enqueues exactly one continuation" do
    one_shot = aged_tombstone

    stub_const(OneShots::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: OneShots::ReapJob do
        assert_enqueued_with(job: OneShots::ReapJob, args: []) do
          OneShots::ReapJob.perform_now
        end
      end
    end

    assert_not OneShot.exists?(one_shot.id)
  end

  test "a full scanned OneShot window continues once after a lost delete" do
    result = Sweeps::Pass.new(counts: { scanned: 2, reaped: 1 }, more: true)

    reap = lambda do |batch:|
      assert_equal 2, batch
      result
    end

    OneShots::Reap.stub(:call, reap) do
      stub_const(OneShots::ReapJob, :BATCH, 2) do
        assert_enqueued_jobs 1, only: OneShots::ReapJob do
          assert_enqueued_with(job: OneShots::ReapJob, args: []) do
            OneShots::ReapJob.perform_now
          end
        end
      end
    end
  end

  private

    def stale_fragment
      payload = { "text" => SecureRandom.hex(6) }
      address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
      @account.content_fragments.create!(
        payload: payload, digest: address.digest
      ).tap do |record|
        ContentFragment.where(id: record.id).update_all(created_at: 2.days.ago)
      end
    end

    def expired_receipt
      one_shot = create_one_shot
      receipt = OneShotCreateReceipt.create!(
        one_shot: one_shot,
        idempotency_key: SecureRandom.uuid,
        request_digest: SecureRandom.hex(32)
      )
      OneShotCreateReceipt.where(id: receipt.id).update_all(created_at: 25.hours.ago)
      [one_shot, receipt]
    end

    def aged_tombstone
      one_shot = create_one_shot
      OneShots::Tombstone.call(one_shot: one_shot)
      OneShot.where(id: one_shot.id).update_all(tombstoned_at: 31.days.ago)
      one_shot
    end

    def create_one_shot
      OneShot.create!(
        account: @account,
        workspace: workspaces(:shared),
        creating_user: users(:member),
        workload: "text_generation"
      ).tap do |one_shot|
        invocation = DevModelLane.create_invocation!(one_shot: one_shot)
        ModelInvocation.where(id: invocation.id).update_all(status: "completed")
      end
    end
end
