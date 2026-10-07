require "test_helper"

# The leaves-first teardown both reclamation routes share.
#
# A ModelInvocation is a second body owner under the same aggregate, and that
# FK carries no cascade. A drain that only collected InferenceRequest-owned bodies would
# therefore fail once diagnostic, response, or reasoning bodies exist.
class InferenceRequests::DrainTest < ActiveJob::TestCase
  setup do
    @account = accounts(:cybros)
    DevModelLane.ensure_enabled!(@account)
  end

  # The invocation's body branch is drained with its aggregate. Nothing writes
  # an invocation-owned body on a InferenceRequest path today, so this
  # writes one directly rather than pretending a writer exists.
  test "an aggregate whose invocation owns a body drains completely" do
    inference_request = aggregate
    invocation = inference_request.model_invocation
    invocation_body(invocation)

    assert_equal 1, InferenceRequests::Drain.call(inference_request_ids: [inference_request.id])

    assert_not InferenceRequest.exists?(inference_request.id)
    assert_not ModelInvocation.exists?(invocation.id)
    assert_empty ContentBody.where(model_invocation_id: invocation.id)
  end

  test "the replay stream dies with its aggregate" do
    inference_request = aggregate
    InferenceRequestEvents::Append.call(
      inference_request: inference_request, idempotency_key: SecureRandom.uuid_v7,
      items: [{ type: "run_status", payload: { "status" => "failed" } }]
    )
    assert_equal 1, InferenceRequestEventItem.where(inference_request_id: inference_request.id).count

    assert_equal 1, InferenceRequests::Drain.call(inference_request_ids: [inference_request.id])

    assert_empty InferenceRequestEventItem.where(inference_request_id: inference_request.id)
    assert_empty InferenceRequestEvent.where(inference_request_id: inference_request.id)
    assert_empty InferenceRequestEventCursor.where(inference_request_id: inference_request.id)
  end

  test "body deletion cascades upload joins from both owner branches" do
    upload = create_upload(media_type: "audio/wav", bytes: wav_bytes)
    inference_request = aggregate(workload: "transcription", input: "a hint", upload: upload)
    invocation_body(inference_request.model_invocation, upload: upload)

    assert_equal 2, ContentBodyUpload.where(content_upload: upload).count
    InferenceRequests::Drain.call(inference_request_ids: [inference_request.id])

    assert_empty ContentBodyUpload.where(content_upload: upload)
    assert_predicate upload.reload.file, :attached?
  end

  # THE ATTEMPT'S FK IS `ON DELETE RESTRICT`, so the reclaimer has to delete
  # it explicitly, and for a while it did not: every route into reclamation
  # raised `PG::RestrictViolation` the moment a tombstoned aggregate had ever
  # been admitted. Both gates pass a TERMINAL invocation through, and a
  # terminal invocation still owns its Attempts — so this drives real
  # admission rather than hand-building a row, because a hand-built Attempt
  # is exactly what the original tests used and exactly why nothing failed.
  test "an aggregate that was admitted drains, attempts and all" do
    inference_request = aggregate
    invocation = inference_request.model_invocation
    assert_equal 1, ModelInvocations::AdmitQueuedWork.call.admitted.length
    assert_equal 1, invocation.reload.attempts.count

    assert_equal 1, InferenceRequests::Drain.call(inference_request_ids: [inference_request.id])

    assert_not InferenceRequest.exists?(inference_request.id)
    assert_not ModelInvocation.exists?(invocation.id)
    assert_empty ModelInvocationAttempt.where(model_invocation_id: invocation.id)
  end

  # Output files ride Active Storage, whose purge discipline hangs off record
  # DESTROY — and the drain deletes in bulk. Without the explicit purge the
  # attachment row and the blob simply outlive the invocation forever.
  test "a drained invocation takes its output files with it" do
    inference_request = aggregate
    invocation = inference_request.model_invocation
    invocation.output_files.attach(
      io: StringIO.new("fake-png-bytes"), filename: "out.png", content_type: "image/png"
    )
    blob_id = invocation.output_files.sole.blob_id

    perform_enqueued_jobs do
      InferenceRequests::Drain.call(inference_request_ids: [inference_request.id])
    end

    assert_equal 0,
      ActiveStorage::Attachment.where(record_type: "ModelInvocation", record_id: invocation.id).count
    assert_not ActiveStorage::Blob.exists?(blob_id), "the blob is reclaimed with its only holder"
  end

  private

    def wav_bytes = "RIFF\x00\x00\x00\x00WAVEfmt #{SecureRandom.hex(4)}".b

    def aggregate(workload: "text_generation", input: "drain me", upload: nil)
      inference_request = InferenceRequest.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: workload
      )
      ContentBodies::Replace.call(
        owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
        entries: Nexus::InputEntries.for(input),
        uploads: Array(upload).compact, seal: true
      )
      DevModelLane.create_invocation!(inference_request: inference_request)
      inference_request.reload
    end

    def invocation_body(invocation, upload: nil)
      result = ContentBodies::Replace.call(
        owner: invocation, role: "response",
        entries: Nexus::InputEntries.for("owned by the invocation"),
        uploads: Array(upload).compact, seal: true
      )
      raise "body refused: #{result.refusal.inspect}" unless result.accepted?

      result.body
    end

    def create_upload(media_type: "image/png", bytes: nil)
      bytes ||= "\x89PNG\r\n\x1a\n#{SecureRandom.hex(4)}".b
      @account.content_uploads.create!(
        creating_user: users(:member),
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "tiny", content_type: media_type
        )
      )
    end
end
