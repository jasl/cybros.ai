require_relative "test_helper"
require "support/bridge"

class TelegramBridgeMediaTest < Minitest::Test
  include TelegramBridgeSupport

  MediaResult = Data.define(:output_text, :files, :error, :finish_quality) do
    def initialize(finish_quality: nil, **) = super
  end
  MediaShot = Data.define(:public_id, :status, :result)
  Accepted = Data.define(:one_shot)
  MediaTask = Data.define(:key, :status, :tool_name, :result) do
    def initialize(result: nil, **) = super
  end
  MediaLoop = Data.define(:tasks)
  MediaDetail = Data.define(:content)

  class MediaClient
    attr_accessor :shot, :loop_row, :task_rows
    attr_reader :calls

    def initialize
      @calls, @task_rows = [], {}
    end

    def workspace(id)
      @calls << [:workspace, id]
      self
    end
    def one_shots = self
    def uploads = self
    def agent_loops = self
    def agent_loop(id)
      @calls << [:agent_loop, id]
      self
    end
    def create(**options)
      @calls << [:create, options]
      Accepted.new(one_shot: @shot)
    end
    def create_io(io, filename:)
      @calls << [:upload, io.read, filename]
      TelegramBridgeSupport::Parent.new(public_id: "uploaded")
    end
    def fetch(id = nil)
      @calls << [:fetch, id]
      id.nil? ? @loop_row : @shot
    end
    def task(key)
      @calls << [:task, key]
      MediaDetail.new(content: @task_rows.fetch(key))
    end
    def cancel(id) = @calls << [:cancel, id]
    def download(id, index)
      @calls << [:download, id, index]
      "audio bytes".b
    end
  end

  def setup
    @core, @client = Core.new, MediaClient.new
    @host = Host.new(home: nil, member_plane: ->(require_workspace:, workspace_public_id: nil, host_public_id: nil) do
      Rho::Extensions::MemberPlane.new(client: @client, workspace_public_id: workspace_public_id || "original")
    end)
    @bridge = Rho::IngressTelegram::Bridge.new(host: @host, core: @core)
  end

  def test_prepared_photo_replays_the_same_input_upload_in_the_original_workspace
    id = @bridge.stage_media(bytes: "image bytes", filename: "photo.jpg", content_type: "image/jpeg",
      idempotency_key: "update-42", workspace_public_id: "original")
    2.times do
      @bridge.submit("conversation", text: "what is this?", speaker: "speaker", idempotency_key: "update-42",
        workspace_public_id: "original", upload_public_ids: [id])
    end
    assert_equal [[:upload, "image bytes", "photo.jpg"]], @client.calls
    assert_equal @core.calls.first, @core.calls.last
    assert_equal ["uploaded"], @core.calls.last.last.fetch(:upload_public_ids)
    assert_equal "original", @core.calls.last.last.fetch(:workspace_public_id)
  end

  def test_voice_transcription_uses_nexus_workload_and_durable_receipt_without_waiting
    @client.shot = MediaShot.new(public_id: "stt", status: "queued", result: nil)
    assert_equal({ "id" => "stt", "status" => "queued" }, @bridge.transcribe(upload_public_id: "voice", model: "dev/stt",
      idempotency_key: "update-42:transcribe", workspace_public_id: "original"))
    assert_equal [:create, { workload: "transcription", model: "dev/stt", input: nil,
      upload_public_ids: ["voice"], idempotency_key: "update-42:transcribe" }], @client.calls.last

    @client.shot = MediaShot.new(public_id: "stt", status: "completed",
      result: MediaResult.new(output_text: "你好，hello", files: [], error: nil))
    assert_equal "你好，hello", @bridge.transcription(id: "stt", workspace_public_id: "original").fetch("text")
    assert_nil @bridge.cancel_media(id: "stt", workspace_public_id: "original")
    assert_equal [:cancel, "stt"], @client.calls.last
    assert @client.calls.select { |call| call.first == :workspace }.all? { |call| call.last == "original" }
  end

  def test_speech_download_uses_returned_file_index_without_exposing_storage_urls
    file = CybrosAgent::Api::OneShotFile.new(index: 2, filename: "voice.mp3", content_type: "audio/mpeg", byte_size: 11)
    @client.shot = MediaShot.new(public_id: "tts", status: "completed", result: MediaResult.new(output_text: nil, files: [file], error: nil))
    result = @bridge.speech_start(text: "你好", model: "dev/tts", idempotency_key: "turn:voice", workspace_public_id: "original")
    assert_equal [:create, { workload: "speech_generation", model: "dev/tts", input: "你好", idempotency_key: "turn:voice" }], @client.calls.last
    assert_equal "tts", result.dig("media", "one_shot_public_id")
    assert_equal "audio bytes", @bridge.media_bytes(result.fetch("media"), workspace_public_id: "original")
    assert_equal [:download, "tts", 2], @client.calls.last
  end

  def test_only_successful_image_tool_capture_is_delivered_not_other_tool_files_or_prose_paths
    @client.loop_row = MediaLoop.new(tasks: [
      MediaTask.new(key: "image", status: "completed", tool_name: "imagegen"),
      MediaTask.new(key: "read", status: "completed", tool_name: "read"),
      MediaTask.new(key: "failed", status: "failed", tool_name: "image_generate"),
      MediaTask.new(key: "empty", status: "completed", tool_name: "image_generate"),
    ])
    @client.task_rows = {
      "image" => [{ "type" => "text", "text" => "saved /private/not-an-upload.png" },
        { "type" => "resource_link", "uri" => "nexus://uploads/picture", "name" => "generated.png", "mimeType" => "image/png", "size" => 100 }],
      "empty" => "no image produced",
    }
    turn = { "status" => "completed", "loop_public_id" => "original-loop", "text" => "[image](/tmp/anything.png)" }
    media = @bridge.turn_media(turn, workspace_public_id: "original")
    assert_equal [{ "upload_public_id" => "picture", "filename" => "generated.png", "content_type" => "image/png", "byte_size" => 100 }], media
    assert_equal [[:task, "image"], [:task, "empty"]], @client.calls.select { |call| call.first == :task }
    assert_equal [[:fetch, nil]], @client.calls.select { |call| call.first == :fetch }
    assert_empty @bridge.turn_media(turn.merge("status" => "canceled"), workspace_public_id: "original")
    assert_includes @client.calls, [:agent_loop, "original-loop"]
  end
  def test_explicit_file_publications_deliver_documents_while_incidental_tool_captures_do_not
    @client.loop_row = MediaLoop.new(tasks: [
      MediaTask.new(key: "published", status: "completed", tool_name: "file_publish"),
      MediaTask.new(key: "incidental", status: "completed", tool_name: "bash"),
      MediaTask.new(key: "error", status: "completed", tool_name: "file_publish", result: { "is_error" => true }),
    ])
    @client.task_rows = { "published" => [
      { "type" => "resource_link", "uri" => "nexus://uploads/report", "name" => "report.pdf", "mimeType" => "application/pdf", "size" => 200 },
    ] }
    media = @bridge.turn_media({ "status" => "completed", "loop_public_id" => "loop" }, workspace_public_id: "original")
    assert_equal [{ "upload_public_id" => "report", "filename" => "report.pdf", "content_type" => "application/pdf", "byte_size" => 200 }], media
    assert_equal [[:task, "published"]], @client.calls.select { |call| call.first == :task }
  end
end
