require "test_helper"

# THE WHOLE BINARY ROUND TRIP, through the public routes and nothing else:
# stage bytes, name them on a OneShot, run the chain, read the transcript
# back. Every other test in this slice owns one link — this one owns that the
# links join.
#
# It is the first test in the repository that carries bytes from a caller all
# the way to a provider request. The transcription workload was assembled,
# lowered and priced long before anything could put audio in.
class AgentAPI::V1::TranscriptionRoundTripTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @token = create_access_token_fixture(user: @human, name: "Member")
    @workspace = workspaces(:shared)
  end

  test "staged audio becomes a transcript the caller reads back" do
    upload = stage_audio

    # THE DETECTION IS VISIBLE TO THE CALLER, and it corrected them: the part was declared
    # audio/mpeg and named.mp3.
    assert_equal "audio/wav", upload.fetch("content_type")
    assert_equal "clip.wav", upload.fetch("filename")

    post one_shots_path, headers: auth, as: :json, params: {
      one_shot: {
        workload: "transcription", model: { model: "dev/mock-transcription" },
        upload_public_ids: [upload.fetch("public_id")],
      },
    }
    assert_response :accepted
    public_id = response.parsed_body.dig("one_shot", "public_id")

    fake_dispatch(json_response(200, { "text" => "the sea was calm" })) do
      perform_enqueued_jobs while enqueued_jobs.any?
    end

    get "#{one_shots_path}/#{public_id}", headers: auth
    assert_response :success
    result = response.parsed_body.dig("one_shot", "result")
    assert_equal "completed", result.fetch("status")
    assert_equal "the sea was calm", result.fetch("output_text")
  end

  # THE BOUND IS THE CREATOR'S. Staging is scoped to (Account, creator) and so
  # is binding, so one member's upload is not another's input — and the
  # refusal says only that the reference is unknown, which is what it says for
  # an id that never existed.
  test "a member cannot name another member's staged upload" do
    theirs = create_access_token_fixture(user: users(:owner), name: "Owner")
    upload = stage_audio(token: theirs)

    post one_shots_path, headers: auth, as: :json, params: {
      one_shot: {
        workload: "transcription", model: { model: "dev/mock-transcription" },
        upload_public_ids: [upload.fetch("public_id")],
      },
    }

    assert_response :unprocessable_content
    assert_equal "unknown_input_upload", response.parsed_body.dig("error", "code")
  end

  # Bytes nothing recognizes are stored honestly as octet-stream, and the lane
  # that admits only audio refuses them — at selection, before any provider is
  # asked to make sense of them.
  test "bytes that are not audio never reach the provider" do
    upload = stage_audio(bytes: SecureRandom.bytes(64), filename: "clip.wav")
    assert_equal "application/octet-stream", upload.fetch("content_type")

    post one_shots_path, headers: auth, as: :json, params: {
      one_shot: {
        workload: "transcription", model: { model: "dev/mock-transcription" },
        upload_public_ids: [upload.fetch("public_id")],
      },
    }

    assert_response :unprocessable_content
    assert_no_enqueued_jobs
  end

  private

    def wav_bytes(rate: 8000)
      samples = "\x00\x00".b * rate
      "RIFF".b + [36 + samples.bytesize].pack("V") + "WAVE".b +
        "fmt ".b + [16, 1, 1, rate, rate * 2, 2, 16].pack("Vv v V V v v") +
        "data".b + [samples.bytesize].pack("V") + samples
    end

    def stage_audio(bytes: wav_bytes, filename: "clip.mp3", token: @token)
      tempfile = Tempfile.new(["audio", File.extname(filename)], binmode: true)
      tempfile.write(bytes)
      tempfile.rewind
      post "/agent_api/v1/uploads",
        params: { upload: { file: Rack::Test::UploadedFile.new(tempfile.path, "audio/mpeg", original_filename: filename) } },
        headers: { "Authorization" => "Bearer #{token.secret}" }
      assert_response :created
      response.parsed_body.fetch("upload")
    end

    def one_shots_path
      "/agent_api/v1/workspaces/#{@workspace.public_id}/one_shots"
    end

    # Create requires an idempotency key; the reads do not mind one.
    def auth(key = SecureRandom.uuid)
      { "Authorization" => "Bearer #{@token.secret}", "Idempotency-Key" => key }
    end
end
