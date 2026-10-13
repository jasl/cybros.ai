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
    assert_no_enqueued_jobs(only: InferenceRequestCreateReceipts::ReapJob) do
      InferenceRequestCreateReceipts::ReapJob.perform_now
    end
    assert_no_enqueued_jobs(only: InferenceRequests::ReapJob) do
      InferenceRequests::ReapJob.perform_now
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
    inference_request, receipt = expired_receipt

    stub_const(InferenceRequestCreateReceipts::ReapJob, :BATCH, 2) do
      assert_no_enqueued_jobs(only: InferenceRequestCreateReceipts::ReapJob) do
        InferenceRequestCreateReceipts::ReapJob.perform_now
      end
    end

    assert_not InferenceRequestCreateReceipt.exists?(receipt.id)
    assert InferenceRequest.exists?(inference_request.id), "receipt cleanup must not collect accepted work"
  end

  test "a full create-receipt batch enqueues exactly one continuation" do
    inference_request, receipt = expired_receipt

    stub_const(InferenceRequestCreateReceipts::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: InferenceRequestCreateReceipts::ReapJob do
        assert_enqueued_with(job: InferenceRequestCreateReceipts::ReapJob, args: []) do
          InferenceRequestCreateReceipts::ReapJob.perform_now
        end
      end
    end

    assert_not InferenceRequestCreateReceipt.exists?(receipt.id)
    assert InferenceRequest.exists?(inference_request.id), "receipt cleanup must not collect accepted work"
  end

  test "a partial InferenceRequest window reaps its tombstones without continuing" do
    inference_request = aged_tombstone

    stub_const(InferenceRequests::ReapJob, :BATCH, 2) do
      assert_no_enqueued_jobs(only: InferenceRequests::ReapJob) do
        InferenceRequests::ReapJob.perform_now
      end
    end

    assert_not InferenceRequest.exists?(inference_request.id)
  end

  test "a full InferenceRequest window enqueues exactly one continuation" do
    inference_request = aged_tombstone

    stub_const(InferenceRequests::ReapJob, :BATCH, 1) do
      assert_enqueued_jobs 1, only: InferenceRequests::ReapJob do
        assert_enqueued_with(job: InferenceRequests::ReapJob, args: []) do
          InferenceRequests::ReapJob.perform_now
        end
      end
    end

    assert_not InferenceRequest.exists?(inference_request.id)
  end

  test "a full scanned InferenceRequest window continues once after a lost delete" do
    result = Sweeps::Pass.new(counts: { scanned: 2, reaped: 1 }, more: true)

    reap = lambda do |batch:|
      assert_equal 2, batch
      result
    end

    InferenceRequests::Reap.stub(:call, reap) do
      stub_const(InferenceRequests::ReapJob, :BATCH, 2) do
        assert_enqueued_jobs 1, only: InferenceRequests::ReapJob do
          assert_enqueued_with(job: InferenceRequests::ReapJob, args: []) do
            InferenceRequests::ReapJob.perform_now
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
      inference_request = create_inference_request
      receipt = InferenceRequestCreateReceipt.create!(
        inference_request: inference_request,
        idempotency_key: SecureRandom.uuid,
        request_digest: SecureRandom.hex(32)
      )
      InferenceRequestCreateReceipt.where(id: receipt.id).update_all(created_at: 25.hours.ago)
      [inference_request, receipt]
    end

    def aged_tombstone
      inference_request = create_inference_request
      InferenceRequests::Tombstone.call(inference_request: inference_request)
      InferenceRequest.where(id: inference_request.id).update_all(tombstoned_at: 31.days.ago)
      inference_request
    end

    def create_inference_request
      InferenceRequest.create!(
        account: @account,
        workspace: workspaces(:shared),
        creating_user: users(:member),
        workload: "text_generation"
      ).tap do |inference_request|
        invocation = DevModelLane.create_invocation!(inference_request: inference_request)
        ModelInvocation.where(id: invocation.id).update_all(status: "completed")
      end
    end
end
