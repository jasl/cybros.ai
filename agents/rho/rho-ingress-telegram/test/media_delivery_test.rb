require "support/runtime"

class TelegramMediaDeliveryTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @bridge.define_singleton_method(:media_bytes) { |_descriptor, **| "image bytes" }
    @client.define_singleton_method(:upload) do |method, params, **fields|
      call(method, params.merge(fields))
    end
  end

  def test_text_and_image_share_one_receipt_and_do_not_repeat_text_after_media_429
    @state.enqueue("answer", route: { "chat_id" => "1", "group" => false }, text: "Here is the image.",
      workspace_public_id: "workspace-home", media: [image])
    sender = delivery
    sender.flush
    @now += 2
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 429, description: "wait", retry_after: 5)
    sender.flush
    @now += 5
    sender.flush
    assert_equal %w[sendMessage sendPhoto sendPhoto], @client.calls.map(&:first)
    assert_equal "sent", @state.read.fetch("deliveries").fetch("answer").fetch("status")
    assert_equal "image bytes", @client.calls.last.last.fetch(:bytes)
  end

  def test_refused_photo_falls_back_to_document_but_ambiguous_media_is_not_retried
    @state.enqueue("image", route: { "chat_id" => "1", "group" => false }, text: "",
      workspace_public_id: "workspace-home", media: [image])
    sender = delivery
    @client.failure = Rho::IngressTelegram::Client::Refused.new(code: 400, description: "dimensions")
    sender.flush
    @client.failure = Rho::IngressTelegram::Client::Unavailable.new(reason: :read, ambiguous: true)
    sender.flush
    @state.bind(42)
    @now += 60
    sender.flush
    assert_equal %w[sendPhoto sendDocument], @client.calls.map(&:first)
    assert_equal "uncertain", @state.read.fetch("deliveries").fetch("image").fetch("status")
  end

  def test_source_is_checked_again_after_media_download_before_post
    @state.enqueue("image", route: { "chat_id" => "1", "group" => false }, text: "",
      workspace_public_id: "workspace-home", media: [image])
    current = true
    @bridge.define_singleton_method(:media_bytes) { |*, **| current = false; "image bytes" }
    delivery.flush { current }
    assert_empty @client.calls
    assert_equal "pending", @state.read.fetch("deliveries").fetch("image").fetch("status")
  end

  def test_unsupported_voice_format_uses_document
    @state.enqueue("voice", route: { "chat_id" => "1", "group" => false }, text: "", voice: true,
      workspace_public_id: "workspace-home", media: [image.merge("filename" => "voice.wav", "content_type" => "audio/wav")])
    delivery.flush
    assert_equal "sendDocument", @client.calls.first.first
  end

  def test_oversized_output_is_refused_without_repeated_downloads
    @state.enqueue("image", route: { "chat_id" => "1", "group" => false }, text: "",
      workspace_public_id: "workspace-home", media: [image.merge("byte_size" => 51 * 1024 * 1024)])
    @bridge.define_singleton_method(:media_bytes) { |*, **| raise "oversized media should not be fetched" }
    sender = delivery
    sender.flush
    sender.flush
    refute @client.calls.any? { |method, _| %w[sendPhoto sendDocument].include?(method) }
    assert_equal "refused", @state.read.fetch("deliveries").fetch("image").fetch("status")
    assert_includes @client.calls.last.last.fetch(:text), "50 MB"
  end

  def test_missing_persisted_capture_is_refused_once_without_blocking_another_chat
    @state.enqueue("image", route: { "chat_id" => "1", "group" => false }, text: "",
      workspace_public_id: "workspace-home", media: [image])
    @state.enqueue("other-chat", route: { "chat_id" => "2", "group" => false }, text: "Still available")
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    downloads = 0
    @bridge.define_singleton_method(:media_bytes) do |*, **|
      downloads += 1
      raise Rho::Core::Refused.new("Not found", code: "not_found", status: 404)
    end

    sender = delivery
    sender.flush { true } # The unchanged final turn remains readable after execution detail collection.
    assert_equal "refused", @state.read.fetch("deliveries").fetch("image").fetch("status")
    assert_equal "sent", @state.read.fetch("deliveries").fetch("other-chat").fetch("status")
    @now += 2
    sender.flush { true }
    @now += 2
    sender.flush { true }

    assert_equal 1, downloads
    assert_equal %w[sendMessage sendMessage], @client.calls.map(&:first)
    assert_includes @client.calls.last.last.fetch(:text), "no longer available"
    assert_equal "1", @client.calls.last.last.fetch(:chat_id)
  end

  def test_missing_one_shot_file_is_refused_but_a_transient_read_keeps_the_receipt_pending
    @state.enqueue("voice", route: { "chat_id" => "1", "group" => false }, text: "", voice: true,
      workspace_public_id: "workspace-home", media: [image.merge("one_shot_public_id" => "speech", "index" => 0)])
    @bridge.define_singleton_method(:media_bytes) { |*, **| raise CybrosAgent::Api::ServerError, "Unavailable" }
    sender = delivery
    assert_raises(CybrosAgent::Api::ServerError) { sender.flush }
    assert_equal "pending", @state.read.fetch("deliveries").fetch("voice").fetch("status")
    assert_empty @client.calls

    @bridge.define_singleton_method(:media_bytes) { |*, **| raise CybrosAgent::Api::NotFound, "Not found" }
    sender.flush
    sender.flush
    assert_equal "refused", @state.read.fetch("deliveries").fetch("voice").fetch("status")
    assert_equal ["sendMessage"], @client.calls.map(&:first)
  end

  private

    def image
      { "upload_public_id" => "upload", "filename" => "image.png", "content_type" => "image/png", "byte_size" => 11 }
    end

    def delivery
      Rho::IngressTelegram::Delivery.new(client: @client, bridge: @bridge, state: @state,
        limits: Rho::IngressTelegram::RateLimit.new(clock: -> { @now }), clock: -> { @now })
    end
end
