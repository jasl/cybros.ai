require "test_helper"
require "json"
require "securerandom"
require "stringio"
require "support/actor_provisioning"

# THE OTHER FOUR WORKLOADS, THROUGH A DEPLOYED SYSTEM.
#
# Until now exactly one protocol family had ever traversed the chain end to
# end: text, over SSE. The catalog declares five, the fake provider serves all
# five wires, and nothing had ever put the other four through a booted Puma, a
# real socket, and an executor in another process. Each of these lanes is a
# DIFFERENT protocol class, a different response shape, and a different pricing
# rate — `per_image`, `per_mchar`, `input_per_mtok` — so the chain being green
# for text says very little about them.
#
# TRANSCRIPTION ARRIVED WITH ITS WRITER. It was absent here for as long as
# nothing in this application could create a ContentUpload — its input is
# audio, audio arrives as an upload, and no upload route existed. The lane
# below is the first thing in this suite to carry bytes from a caller all the
# way to a provider request, and it needs no fixture in the repository: the
# speech lane makes the audio that the transcription lane reads back.
class InferenceRequestWorkloadsTest < Minitest::Test
  TURN_TIMEOUT = 60
  POLL = 1.0

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(
      name: "InferenceRequest workloads #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).workspace
    @lane = @client.workspace(@workspace.public_id).inference_requests
  end

  # EMBEDDING is the one workload whose answer is not prose, and the wire says so: the vectors
  # arrive TYPED on the result as `embeddings: [{index, vector}]` — the SDK reads `InferenceRequestEmbedding`
  # values — and `output_text` is absent on that workload. There is no JSON document to parse out of
  # the prose slot any more.
  def test_an_embedding_returns_its_vectors_typed_through_the_deployed_chain
    inference_request = run_turn(
      workload: "embedding", model: "dev/mock-embedding",
      input: "!mock usage=11:0 -- embed me", configuration: { "dimensions" => 3 }
    )

    assert_equal "completed", inference_request.status
    assert_nil inference_request.output_text, "the vectors are the answer; there is no prose"

    embeddings = inference_request.result.embeddings
    assert_equal [0], embeddings.map(&:index)
    vector = embeddings.first.vector
    assert_equal 3, vector.length,
      "the requested dimensionality must survive the whole chain"
    assert(vector.all?(Numeric), "a vector of numbers, not of strings")
    assert_equal [vector], inference_request.result.vectors
    assert_equal 11, inference_request.result.usage.input_tokens
    assert_empty inference_request.result.files,
      "a workload that produces no bytes advertises none, and iterating is still safe"
  end

  # A ROUND TRIP WITH NO FIXTURE. The speech lane produces real audio bytes,
  # the caller downloads them through the API, stages them through the upload
  # route, and the transcription lane reads them back. Nothing binary is
  # checked in, and every link is the deployed one — a booted Puma, a real
  # socket, an executor in another process.
  #
  # THE BYTE COUNT IS THE ASSERTION. The fake provider answers with the size
  # of the audio it actually received, so matching it against the size the
  # upload route reported proves the bytes crossed ingest, storage and the
  # multipart send unaltered. A transcript alone would prove only that
  # something arrived.
  def test_speech_makes_the_audio_that_transcription_reads_back
    spoken = run_turn(
      workload: "speech_generation", model: "dev/mock-speech", input: "!mock usage=5:0 -- say hi"
    )
    assert_equal "completed", spoken.status
    audio = @lane.download(spoken.public_id, spoken.result.files.first.index)
    assert audio.start_with?("RIFF"), "the speech lane's own bytes are the input here"

    upload = @client.uploads.create_io(StringIO.new(audio), filename: "spoken.wav")
    assert_equal audio.bytesize, upload.byte_size,
      "the route reports the size it stored, and it is the size that was sent"
    assert_equal "audio/wav", upload.content_type,
      "the part declared octet-stream; the bytes are what the caller is told"

    transcribed = run_turn(
      workload: "transcription", model: "dev/mock-transcription", input: nil,
      upload_public_ids: [upload.public_id]
    )

    assert_equal "completed", transcribed.status
    assert_equal "Mock transcription of #{audio.bytesize} bytes", transcribed.output_text,
      "the provider saw exactly the bytes the caller staged"
    assert_empty transcribed.result.files, "a transcript is prose, not a file"
  end

  private

    def run_turn(workload:, model:, input:, configuration: nil, upload_public_ids: nil)
      created = @lane.create(
        workload: workload, model: model, input: input,
        idempotency_key: SecureRandom.uuid,
        **(configuration ? { configuration: configuration } : {}),
        **(upload_public_ids ? { upload_public_ids: upload_public_ids } : {})
      )
      refute_predicate created, :finished?, "creation is asynchronous by contract"
      await_terminal(created.public_id)
    end

    def await_terminal(public_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        last = @lane.fetch(public_id)
        return last if last.finished?

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk("#{public_id} never reached a terminal state; last read: #{last.inspect}")
        end
        sleep POLL
      end
    end
end
