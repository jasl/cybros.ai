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
    )
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

  # SPEECH's provider answers with RAW AUDIO BYTES — not JSON, not SSE — so it
  # is the lane that proves the protocol layer can read a non-JSON success at
  # all. What a caller reads back is deliberately thin, and asserted as such:
  # the bytes are persisted to Active Storage on the invocation and no API
  # surface serves them, so there is nothing here but a completed status and a
  # receipt. That is the honest state, and the lane says so out loud.
  def test_speech_completes_on_a_non_json_wire_and_answers_with_no_text
    inference_request = run_turn(
      workload: "speech_generation", model: "dev/mock-speech", input: "!mock usage=5:0 -- say hi"
    )

    assert_equal "completed", inference_request.status,
      "a raw audio body is a success the protocol layer must be able to read"
    assert_nil inference_request.output_text,
      "no text is produced, and none is invented — prose is not the answer here"

    # THE ANSWER IS THE FILE. It came back through the API rather than from
    # storage, which is the whole point: the same containment that guards the
    # run guards its bytes.
    files = inference_request.result.files
    assert_equal 1, files.length, "one utterance is one file"
    file = files.first
    assert_equal 0, file.index
    assert_operator file.byte_size, :>, 0
    audio = @lane.download(inference_request.public_id, file.index)
    assert_equal file.byte_size, audio.bytesize
    assert audio.start_with?("RIFF"), "the bytes must be the WAV the provider sent, unaltered"

    # A SPEECH RECEIPT CARRIES NO QUANTITIES AT ALL. There is nowhere for them
    # to come from: the wire answers with audio bytes and no usage block, and
    # the lane is priced per character rather than per token. So the receipt is
    # a cost and a timing and nothing else — asserted rather than assumed,
    # because a caller reaching for `total_tokens` here gets nil.
    usage = inference_request.result.usage
    assert_nil usage.input_tokens
    assert_nil usage.total_tokens
    assert_predicate usage, :cost_complete,
      "no token counts is not the same as no answer for the cost"
    assert_operator inference_request.usage_summary.request_count, :>=, 1
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

  # IMAGE is priced PER IMAGE rather than per token, so the count the provider
  # delivered is a billing fact and not a detail — which makes `result_count`
  # the one generation parameter on this lane worth sending. It also happens to
  # be the parameter that used to make this create return 500.
  def test_an_image_turn_completes_with_the_requested_count_priced
    inference_request = run_turn(
      workload: "image_generation", model: "dev/mock-image",
      input: "!mock usage=3:0 -- draw a cat", configuration: { "result_count" => 2 }
    )

    assert_equal "completed", inference_request.status
    assert_nil inference_request.output_text,
      "this provider sends no revised prompt; the images are not prose"
    refute_nil inference_request.result.usage, "a delivered image is a billed image"
    assert_predicate inference_request.result.usage, :cost_complete,
      "a known-free lane must still answer for its cost"

    # BOTH images, in the order the provider sent them, each downloadable. Two
    # is the smallest count that can expose an ordering bug, which matters here
    # because the association carries no ORDER BY of its own.
    files = inference_request.result.files
    assert_equal [0, 1], files.map(&:index)
    assert_equal %w[image/png image/png], files.map(&:content_type)
    files.each do |file|
      bytes = @lane.download(inference_request.public_id, file.index)
      assert_equal file.byte_size, bytes.bytesize
      assert bytes.start_with?("\x89PNG".b), "index #{file.index} did not come back as a PNG"
    end
  end

  # A non-retryable refusal on a non-text wire has to arrive as a typed terminal too.
  # The provider rejects the unary embedding request before returning a workload result.
  def test_a_unary_provider_failure_is_terminal_on_a_non_text_lane
    inference_request = run_turn(
      workload: "embedding", model: "dev/mock-embedding", input: "!mock error=400 -- embed me"
    )

    refute_equal "completed", inference_request.status
    refute_nil inference_request.result.error, "a refused turn names why on the result envelope"
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
