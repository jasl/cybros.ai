require_relative "test_helper"

class TelegramClientTest < Minitest::Test
  Client = Rho::IngressTelegram::Client

  def setup
    @server = TelegramTest::FakeTelegram.new
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    @server.stop
  end

  def test_long_poll_does_not_block_sends_and_raw_updates_survive
    Async do |task|
      task.with_timeout(3) do
        client = build_client
        poll = task.async { client.call("getUpdates", { timeout: 2, hold: "concurrent" }, poll: true) }
        await_request(task, "getUpdates", hold: "concurrent")
        result = client.call("sendMessage", { chat_id: 123, text: "hello" })
        assert_equal 99, result.fetch("message_id")
        refute poll.finished?, "the send completed while the poll was still held"
        @server.release("concurrent")
        update = poll.wait.first
        assert_equal "preserved", update.dig("stopped_message_generation", "future_field")
        assert_equal({ "value" => 7 }, update.fetch("future_update_field"))
      end
    end.wait
  end

  def test_future_method_and_rich_payload_are_not_filtered_by_generated_types
    Async do
      result = build_client.call("futureTelegramMethod", {
        chat_id: 123, rich_message: { markdown: "**hello**" }, can_stop: true, keep_on_stop: true,
      })
      received = result.fetch("received")
      assert_equal({ "markdown" => "**hello**" }, JSON.parse(received.fetch("rich_message")))
      assert_equal "true", received.fetch("can_stop")
      assert_equal "true", received.fetch("keep_on_stop")
    end.wait
  end

  def test_rate_limit_is_a_definite_refusal_with_retry_after_and_no_retry
    Async do
      error = assert_raises(Client::Refused) { build_client.call("rateLimited") }
      assert_equal 429, error.code
      assert_equal 7, error.retry_after
      assert_nil error.cause
      assert_equal 1, @server.count("rateLimited")
    end.wait
  end

  def test_error_message_and_cause_never_include_the_token
    Async do
      client = build_client
      error = assert_raises(Client::Refused) { client.call("badFormatting") }
      assert_equal 400, error.code
      assert_includes error.description, "cannot parse"
      refute_includes error.full_message, TelegramTest::FakeTelegram::TOKEN
      refute_includes client.inspect, TelegramTest::FakeTelegram::TOKEN
      assert_nil error.cause
    end.wait
  end

  def test_server_failures_and_redirects_are_not_retried_or_followed
    Async do
      client = build_client
      %w[serverError nonJsonError redirect].each do |method|
        error = assert_raises(Client::Unavailable) { client.call(method) }
        assert error.ambiguous
        assert_nil error.cause
        assert_equal 1, @server.count(method)
        refute_includes error.full_message, TelegramTest::FakeTelegram::TOKEN
      end
      assert_equal 0, @server.count("redirectTarget")
    end.wait
  end

  def test_lost_post_response_is_ambiguous_and_sent_only_once
    Async do
      error = assert_raises(Client::Unavailable) { build_client.call("ambiguousSend") }
      assert error.ambiguous
      assert_equal :connection, error.reason
      assert_equal 1, @server.count("ambiguousSend")
    end.wait
  end

  def test_invalid_response_is_safe_and_not_retried
    Async do
      error = assert_raises(Client::Unavailable) { build_client.call("invalidResponse") }
      assert_equal :invalid_response, error.reason
      assert error.ambiguous
      refute_includes error.full_message, TelegramTest::FakeTelegram::TOKEN
      assert_nil error.cause
      assert_equal 1, @server.count("invalidResponse")
    end.wait
  end

  def test_poll_http_timeout_is_finite_and_not_retried
    Async do |task|
      task.with_timeout(2) do
        error = assert_raises(Client::Unavailable) do
          build_client(poll_timeout: 0.1).call("getUpdates", { hold: "timeout" }, poll: true)
        end
        assert_equal :timeout, error.reason
        assert_equal 1, @server.count("getUpdates", hold: "timeout")
      end
    end.wait
  end

  def test_close_cancels_outstanding_poll_without_waiting_for_remote_timeout
    Async do |task|
      task.with_timeout(2) do
        client = build_client(poll_timeout: 30)
        poll = task.async do
          assert_raises(Client::Unavailable) { client.call("getUpdates", { hold: "close" }, poll: true) }
        end
        await_request(task, "getUpdates", hold: "close")
        client.close
        error = poll.wait
        assert_equal :closed, error.reason
        assert error.ambiguous
        error = assert_raises(Client::Unavailable) { client.call("sendMessage", { text: "too late" }) }
        refute error.ambiguous
        assert_equal 0, @server.count("sendMessage")
      end
    end.wait
  end

  def test_caller_cancellation_and_close_do_not_hang
    Async do |task|
      task.with_timeout(2) do
        client = build_client(poll_timeout: 30)
        finalized = false
        poll = task.async do
          client.call("getUpdates", { hold: "cancel" }, poll: true)
        ensure
          finalized = true
        end
        await_request(task, "getUpdates", hold: "cancel")
        poll.stop
        client.close
        assert finalized
        assert_equal 1, @server.count("getUpdates", hold: "cancel")
      end
    end.wait
  end

  def test_invalid_client_configuration_is_refused_before_io
    assert_raises(ArgumentError) { build_client(token: "") }
    assert_raises(ArgumentError) { build_client(url: "file:///tmp/telegram") }
    assert_raises(ArgumentError) { build_client(url: "https://api.telegram.org/path") }
    assert_raises(ArgumentError) { build_client(timeout: Float::INFINITY) }
    assert_raises(ArgumentError) { build_client(poll_timeout: 0) }
  end

  def test_invalid_method_is_refused_before_io
    Async do
      assert_raises(ArgumentError) { build_client.call("../token") }
      assert_equal 0, @server.count("token")
    end.wait
  end

  private

  def build_client(**options)
    client = Client.new(token: TelegramTest::FakeTelegram::TOKEN, url: @server.url, **options)
    @clients << client
    client
  end

  def await_request(task, method, **options)
    task.with_timeout(1) do
      sleep(0.005) until @server.count(method, **options).positive?
    end
  end
end
