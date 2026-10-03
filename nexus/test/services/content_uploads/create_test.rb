require "test_helper"

# THE INGEST DOOR. Three things have to be true of it, and the predecessor's
# equivalent was true of none of them: the size bound it advertises is real,
# the stored type comes from the bytes rather than from the caller's claim,
# and a refusal leaves nothing behind.
class ContentUploads::CreateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
    @user = users(:member)
  end

  # A real RIFF/WAVE header — the bytes Marcel actually recognizes, not a
  # string that merely starts with "RIFF".
  def wav_bytes(seconds: 1, rate: 8000)
    samples = "\x00\x00".b * (rate * seconds)
    "RIFF".b + [36 + samples.bytesize].pack("V") + "WAVE".b +
      "fmt ".b + [16, 1, 1, rate, rate * 2, 2, 16].pack("Vv v V V v v") +
      "data".b + [samples.bytesize].pack("V") + samples
  end

  def uploaded(bytes, filename:, content_type:)
    tempfile = Tempfile.new(["ingest", File.extname(filename)], binmode: true)
    tempfile.write(bytes)
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(
      tempfile: tempfile, filename: filename, type: content_type
    )
  end

  def create(file) = ContentUploads::Create.call(account: @account, creator: @user, file: file)

  test "the bytes decide the type, not the caller" do
    result = create(uploaded(wav_bytes, filename: "clip.mp3", content_type: "audio/mpeg"))

    assert_predicate result, :accepted?
    blob = result.upload.file
    assert_equal "audio/x-wav", blob.content_type,
      "a caller's declared type must not become the stored truth"
    assert_equal "clip.wav", blob.filename.to_s,
      "and the extension follows the bytes, because the provider reads it"
  end

  # MEASURED, NOT ASSUMED: OpenAI's transcription endpoint refuses the same
  # WAV bytes with "Unsupported file format" when the filename carries no
  # extension, so an extensionless upload would be a provider refusal we
  # handed the caller.
  test "a name with no extension gains the one the bytes imply" do
    result = create(uploaded(wav_bytes, filename: "clip", content_type: "application/octet-stream"))

    assert_equal "clip.wav", result.upload.file.filename.to_s
  end

  # `audio/mp4` lists mp4a, m4a and m4b. Only the caller knows which it meant,
  # and rewriting a working `.m4a` to the table's first entry would produce a
  # spelling providers do not accept.
  test "an extension the detected type already allows is left alone" do
    m4a = "\x00\x00\x00\x20ftypM4A \x00\x00\x00\x00M4A mp42isom".b + ("\x00".b * 64)
    result = create(uploaded(m4a, filename: "voice.m4a", content_type: "audio/mp4"))

    skip("this build's Marcel does not detect the fixture as audio/mp4") unless
      result.upload.file.content_type == "audio/mp4"
    assert_equal "voice.m4a", result.upload.file.filename.to_s
  end

  test "unrecognizable bytes stay unrecognized rather than borrowing the claim" do
    result = create(uploaded(SecureRandom.bytes(64), filename: "a.wav", content_type: "audio/wav"))

    assert_equal "application/octet-stream", result.upload.file.content_type
  end

  test "ordinary files retain their extension without promoting it into MIME evidence" do
    { "notes.md" => "# Notes\n", "script.py" => "print('hello')\n", "opaque.docx" => "unknown document bytes" }.each do |filename, bytes|
      result = create(uploaded(bytes, filename: filename, content_type: "application/pdf"))
      assert_equal filename, result.upload.filename.to_s
      assert_not_equal "application/pdf", result.upload.content_type
    end
  end

  # THE BOUND IS REAL, AND REFUSING COSTS NOTHING. Both halves are asserted:
  # a refusal that had already handed the bytes to storage would be a leak
  # wearing a refusal's clothes.
  test "an oversize upload is refused before anything is stored" do
    oversize = Tempfile.new("huge", binmode: true)
    oversize.truncate(Nexus::SizeBounds.fetch(:upload_bound) + 1)
    file = ActionDispatch::Http::UploadedFile.new(
      tempfile: oversize, filename: "huge.bin", type: "application/octet-stream"
    )

    assert_no_difference ["ContentUpload.count", "ActiveStorage::Blob.count"] do
      result = create(file)

      assert_not_predicate result, :accepted?
      assert_equal :content_too_large, result.refusal
    end
  end

  test "an upload exactly at the bound is accepted" do
    exact = Tempfile.new("edge", binmode: true)
    exact.truncate(Nexus::SizeBounds.fetch(:upload_bound))
    file = ActionDispatch::Http::UploadedFile.new(
      tempfile: exact, filename: "edge.bin", type: "application/octet-stream"
    )

    assert_predicate create(file), :accepted?
  end

  # `has_one_attached:file, analyze::lazily` exists so ingest never pays to re-download what it just
  # wrote. Analysis on the write path would read the whole blob back for metadata nothing here asks
  # for.
  test "ingest analyzes nothing" do
    assert_no_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
      create(uploaded(wav_bytes, filename: "clip.wav", content_type: "audio/wav"))
    end
  end

  # The one normalization point stays one: Active Storage stores the Marcel
  # spelling and the model translates it for every internal consumer.
  test "the stored spelling is normalized by the model, not by ingest" do
    upload = create(uploaded(wav_bytes, filename: "clip.wav", content_type: "audio/wav")).upload

    assert_equal "audio/x-wav", upload.file.content_type
    assert_equal "audio/wav", upload.content_type
  end
end
