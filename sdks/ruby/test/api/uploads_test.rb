require "test_helper"

# Staging bytes: the one non-JSON request this family makes.
class ApiUploadsTest < Minitest::Test
  DESCRIPTOR = {
    "upload" => {
      "public_id" => "01a0-upload", "filename" => "clip.wav",
      "content_type" => "audio/wav", "byte_size" => 2048,
      "created_at" => "2026-08-27T00:00:00Z",
    },
  }.freeze

  def setup
    @transport = CybrosAgentTest::FakeTransport.new([[201, {}, DESCRIPTOR]])
    @client = CybrosAgent::Client.new(
      base_url: "https://nexus.test", credential: "sk-cybros-api-v1-x", transport: @transport
    )
  end

  def test_create_streams_the_file_as_one_multipart_part
    Tempfile.create(["clip", ".wav"], binmode: true) do |file|
      file.write("RIFF____WAVEfmt ")
      file.flush

      upload = @client.uploads.create(file.path)

      assert_equal "01a0-upload", upload.public_id
      assert_equal "audio/wav", upload.content_type
      assert_equal 2048, upload.byte_size

      request = only_request
      assert_equal "/agent_api/v1/uploads", request.fetch(:path)
      assert_equal :post, request.fetch(:method)
      assert_nil request.fetch(:body), "an upload is not a JSON body"

      part = request.fetch(:form).fetch(:upload).fetch(:file)
      assert_equal File.basename(file.path), part.filename
      # THE HANDLE, NOT THE BYTES. What reaches the transport is something to
      # read from — the file is never loaded here, and httpx's multipart
      # encoder streams it.
      assert_respond_to part, :read
    end
  end

  # THE SERVER DECIDES THE TYPE, so the part declares the neutral one. A guess
  # here would be a claim the server is right to ignore, and the caller would
  # read back a different answer than they sent.
  def test_the_part_declares_no_opinion_about_the_type
    Tempfile.create(["clip", ".wav"], binmode: true) do |file|
      file.write("RIFF")
      file.flush
      @client.uploads.create(file.path)
    end

    part = only_request.fetch(:form).fetch(:upload).fetch(:file)
    assert_equal "application/octet-stream", part.content_type
  end

  # THE WHOLE ENCODER, not just the part builder. Two different pieces of the
  # duck are needed and each was missing once: httpx builds a part from a Hash
  # whose `:body` is an IO by checking for a `path`, so in-memory bytes ship as
  # "#<StringIO:0x...>" — and the encoder then sums every part's `size` to
  # declare Content-Length before reading anything. Driving `Encoder` end to
  # end is what makes this test able to fail for either reason.
  def test_the_real_encoder_carries_the_bytes_and_can_measure_them
    @client.uploads.create_io(StringIO.new("REAL BYTES"), filename: "clip.wav")

    encoder = HTTPX::Transcoder::Multipart::Encoder.new(
      only_request.fetch(:form).fetch(:upload)
    )
    body = encoder.read

    assert_operator encoder.bytesize, :>, 0, "the encoder must be able to measure the part"
    assert_includes body, "REAL BYTES"
    assert_includes body, %(filename="clip.wav")
    assert_includes body, "application/octet-stream"
  end

  def test_create_io_uploads_from_the_current_position_and_measures_only_what_remains
    io = StringIO.new("already consumed|REAL BYTES")
    io.pos = "already consumed|".bytesize
    @client.uploads.create_io(io, filename: "clip.wav")

    part = only_request.fetch(:form).fetch(:upload).fetch(:file)
    assert_equal "REAL BYTES".bytesize, part.size

    encoder = HTTPX::Transcoder::Multipart::Encoder.new(
      only_request.fetch(:form).fetch(:upload)
    )
    body = encoder.read

    assert_equal encoder.bytesize, body.bytesize,
      "the declared multipart length must equal the bytes the encoder can still read"
    assert_includes body, "REAL BYTES"
    refute_includes body, "already consumed"
  end

  def test_create_closes_the_handle_it_opened
    handles = ObjectSpace.each_object(File).count { |f| !f.closed? }

    Tempfile.create(["clip", ".wav"], binmode: true) do |file|
      file.write("RIFF")
      file.flush
      @client.uploads.create(file.path)
    end

    assert_equal handles, ObjectSpace.each_object(File).count { |f| !f.closed? },
      "the context opened the file, so the context closes it"
  end

  def test_fetch_reads_a_staged_upload_back
    @transport = CybrosAgentTest::FakeTransport.new([[200, {}, DESCRIPTOR]])
    client = CybrosAgent::Client.new(
      base_url: "https://nexus.test", credential: "sk-cybros-api-v1-x", transport: @transport
    )

    upload = client.uploads.fetch("01a0-upload")

    assert_equal "clip.wav", upload.filename
    assert_equal "/agent_api/v1/uploads/01a0-upload", @transport.requests.first.fetch(:path)
  end

  # THE ONE BYTES READ: the upload's bytes stream INTO the IO
  # the caller holds — the transport's `sink:`, passed only here — a whole
  # read expecting 200, a `Range` read expecting 206; the failure ladder is
  # every other read's, so an upload the credential may not read is
  # NotFound and never an empty file.
  def test_bytes_streams_the_upload_into_the_io_whole_or_by_range
    @transport = CybrosAgentTest::FakeTransport.new([
      [200, { "content-type" => "image/png" }, "PNGBYTES"],
      [206, { "content-range" => "bytes 3-7/8" }, "BYTES"],
      [404, {}, { "error" => { "code" => "not_found" } }],
    ])
    client = CybrosAgent::Client.new(
      base_url: "https://nexus.test", credential: "sk-cybros-api-v1-x", transport: @transport
    )

    whole = StringIO.new
    read = client.uploads.bytes("01a0-upload", whole)
    assert_instance_of CybrosAgent::Api::AttachmentRead, read
    assert_equal 200, read.status
    refute_predicate read, :unchanged?
    assert_nil read.etag, "no tag came back: none to hand on"
    assert_equal "PNGBYTES", whole.string
    request = @transport.requests.fetch(0)
    assert_equal "/agent_api/v1/uploads/01a0-upload/bytes", request.fetch(:path)
    assert_equal :get, request.fetch(:method)
    assert_equal CybrosAgent::ANY_MEDIA, request.fetch(:accept), "bytes, not structure"
    assert_same whole, request.fetch(:sink), "the caller's IO is the sink"
    refute request.fetch(:headers).key?("Range")

    tail = StringIO.new
    assert_equal 206, client.uploads.bytes("01a0-upload", tail, range: "bytes=3-7").status
    assert_equal "BYTES", tail.string
    assert_equal "bytes=3-7", @transport.requests.fetch(1).fetch(:headers).fetch("Range")
    refute @transport.requests.fetch(1).fetch(:headers).key?("If-None-Match"), "no tag, no condition"

    nothing = StringIO.new
    assert_raises(CybrosAgent::Api::NotFound) { client.uploads.bytes("01a0-gone", nothing) }
    assert_equal "", nothing.string, "a refusal writes nothing into the IO"
  end

  # A 200 where 206 was asked for is a server that ignored the Range — a
  # malformed answer to THIS request, never silently a whole file in a
  # buffer sized for a slice.
  def test_bytes_refuses_a_whole_answer_to_a_range_read
    @transport = CybrosAgentTest::FakeTransport.new([[200, {}, "WHOLE"]])
    client = CybrosAgent::Client.new(
      base_url: "https://nexus.test", credential: "sk-cybros-api-v1-x", transport: @transport
    )

    assert_raises(CybrosAgent::Api::MalformedResponse) do
      client.uploads.bytes("01a0-upload", StringIO.new, range: "bytes=0-4")
    end
  end

  # THE CONDITIONAL READ: the tag a read answered rides the next
  # one as `If-None-Match`; the server's 304 is the typed `unchanged?`
  # answer with nothing written — never an exception — and only a read
  # that asked can be answered so.
  def test_a_read_carries_the_tag_and_a_conditional_read_answers_unchanged_as_a_typed_result
    @transport = CybrosAgentTest::FakeTransport.new([
      [200, { "ETag" => '"abc123"', "Cache-Control" => "private, max-age=31556952" }, "PNGBYTES"],
      [304, { "etag" => '"abc123"' }, nil],
      [304, {}, nil],
    ])
    client = CybrosAgent::Client.new(
      base_url: "https://nexus.test", credential: "sk-cybros-api-v1-x", transport: @transport
    )

    first = client.uploads.bytes("01a0-upload", StringIO.new)
    assert_equal '"abc123"', first.etag

    again = StringIO.new
    second = client.uploads.bytes("01a0-upload", again, etag: first.etag)
    assert_predicate second, :unchanged?
    assert_equal 304, second.status
    assert_equal '"abc123"', second.etag, "the header's case is the server's; the tag is read either way"
    assert_equal "", again.string, "unchanged writes nothing"
    assert_equal '"abc123"', @transport.requests.fetch(1).fetch(:headers).fetch("If-None-Match")

    assert_raises(CybrosAgent::Api::MalformedResponse, "a 304 nobody asked for is malformed") do
      client.uploads.bytes("01a0-upload", StringIO.new)
    end
  end

  # THE TWO NAMED REPRESENTATION READS: the thumbnail and the
  # preview on their nested paths, whole (no range), the same typed answer
  # and the same condition as `bytes`; an upload with no representation of
  # that kind is NotFound under its own code, and nothing is written.
  def test_thumbnail_and_preview_are_named_reads_with_the_same_answer_and_the_typed_refusal
    @transport = CybrosAgentTest::FakeTransport.new([
      [200, { "ETag" => '"thumb"', "Content-Type" => "image/png" }, "SMALLPNG"],
      [304, { "ETag" => '"big"' }, nil],
      [404, {}, { "error" => { "code" => "representation_unavailable", "message" => "no thumbnail" } }],
    ])
    client = CybrosAgent::Client.new(
      base_url: "https://nexus.test", credential: "sk-cybros-api-v1-x", transport: @transport
    )

    small = StringIO.new
    read = client.uploads.thumbnail("01a0-upload", small)
    assert_equal [200, '"thumb"'], [read.status, read.etag]
    assert_equal "SMALLPNG", small.string
    request = @transport.requests.fetch(0)
    assert_equal "/agent_api/v1/uploads/01a0-upload/thumbnail", request.fetch(:path)
    assert_equal :get, request.fetch(:method)
    assert_equal CybrosAgent::ANY_MEDIA, request.fetch(:accept)
    assert_same small, request.fetch(:sink)
    refute request.fetch(:headers).key?("Range"), "a representation is whole"

    kept = StringIO.new
    assert_predicate client.uploads.preview("01a0-upload", kept, etag: '"big"'), :unchanged?
    assert_equal "", kept.string
    assert_equal "/agent_api/v1/uploads/01a0-upload/preview", @transport.requests.fetch(1).fetch(:path)
    assert_equal '"big"', @transport.requests.fetch(1).fetch(:headers).fetch("If-None-Match")

    nothing = StringIO.new
    error = assert_raises(CybrosAgent::Api::NotFound) { client.uploads.thumbnail("01a0-note", nothing) }
    assert_equal "representation_unavailable", error.code
    assert_equal "", nothing.string
  end

  # THE EXECUTOR PLANE'S CAPTURES: the same staging body on the
  # executor door, under the transport credential; no fetch, no bytes.
  def test_an_executor_stages_a_capture_on_its_own_door
    transport = CybrosAgentTest::FakeTransport.new([[201, {}, DESCRIPTOR]])
    executor = CybrosAgent::ExecutorClient.new(
      base_url: "https://nexus.test", credential: "sk-cybros-executor-v1-x", transport: transport
    )

    upload = executor.uploads.create_io(StringIO.new("PNG"), filename: "shot.png")

    assert_equal "01a0-upload", upload.public_id
    request = transport.requests.fetch(0)
    assert_equal "/agent_api/v1/executor/uploads", request.fetch(:path)
    assert_equal :post, request.fetch(:method)
    assert_equal "sk-cybros-executor-v1-x", request.fetch(:credential)
    part = request.fetch(:form).fetch(:upload).fetch(:file)
    assert_equal "shot.png", part.filename
    assert_equal 3, part.size
    refute_respond_to executor.uploads, :fetch, "nothing on this plane reads a capture back"
    refute_respond_to executor.uploads, :bytes
    refute_respond_to executor.uploads, :thumbnail
    refute_respond_to executor.uploads, :preview
  end

  private

    def only_request
      assert_equal 1, @transport.requests.length
      @transport.requests.first
    end
end
