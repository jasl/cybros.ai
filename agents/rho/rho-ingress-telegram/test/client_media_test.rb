require_relative "test_helper"

class TelegramClientMediaTest < Minitest::Test
  Client = Rho::IngressTelegram::Client

  def setup
    @server = TelegramTest::FakeTelegram.new
    @client = Client.new(token: TelegramTest::FakeTelegram::TOKEN, url: @server.url)
  end

  def teardown
    @client.close
    @server.stop
  end

  def test_download_reads_binary_bytes_and_upload_uses_the_gems_multipart_encoder
    Async do
      assert_equal "image-bytes".b, @client.download("photos/file.jpg", max_bytes: 20)
      { "sendPhoto" => "photo", "sendDocument" => "document", "sendVoice" => "voice" }.each do |method, field|
        result = @client.upload(method, { chat_id: 123, message_thread_id: 7 }, bytes: "binary payload",
          filename: "result.png", content_type: "image/png", field: field)
        body = result.dig("received", "multipart_body")
        assert_includes body, "name=\"#{field}\""
        assert_includes body, "filename=\"result.png\""
        assert_includes body, "Content-Type: image/png"
        assert_includes body, "binary payload"
        assert_includes body, "name=\"message_thread_id\""
        assert_equal 1, @server.count(method)
      end
    end.wait
  end

  def test_download_rejects_oversize_actual_body_then_next_download_still_works
    Async do
      error = assert_raises(Client::Refused) { @client.download("large.jpg", max_bytes: 100) }
      assert_equal 413, error.code
      assert_equal 1, @server.count("large.jpg")
      refute_includes error.full_message, TelegramTest::FakeTelegram::TOKEN
      assert_equal "image-bytes", @client.download("file.jpg", max_bytes: 100)
    end.wait
  end

  def test_file_paths_cannot_redirect_or_send_the_token_to_another_destination
    Async do
      ["https://elsewhere.example/file", "/file.jpg", "../file.jpg", "photos/../file.jpg", "file.jpg?redirect=1", "photos%2Ffile.jpg"].each do |path|
        assert_raises(ArgumentError) { @client.download(path, max_bytes: 100) }
      end
      error = assert_raises(Client::Unavailable) { @client.download("file-redirect.jpg", max_bytes: 100) }
      refute error.ambiguous
      assert_equal 0, @server.count("file.jpg")
      refute_includes error.full_message, TelegramTest::FakeTelegram::TOKEN
      assert_nil error.cause
    end.wait
  end

  def test_failed_tls_download_does_not_leak_the_authenticated_url
    wire = @client.instance_variable_get(:@file_api).connection
    wire.define_singleton_method(:get) do |*_args|
      raise Faraday::SSLError, "failed https://api.telegram.org/file/bot#{TelegramTest::FakeTelegram::TOKEN}/file.jpg"
    end
    Async do
      error = assert_raises(Client::Unavailable) { @client.download("file.jpg", max_bytes: 100) }
      refute error.ambiguous
      assert_nil error.cause
      refute_includes error.full_message, TelegramTest::FakeTelegram::TOKEN
    end.wait
  end
end
