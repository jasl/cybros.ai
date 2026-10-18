require "test_helper"
require "stringio"
require "timeout"
require "support/mcp_fixture/controlled_writes"

class McpFixtureControlHarnessTest < Minitest::Test
  def setup
    @control = E2E::McpFixture::ControlledWrites.new
  end

  def test_the_write_is_recorded_before_response_release_and_a_repeat_is_counted
    assert_equal({ "count" => 0, "waiting" => 0 }, command("hold", "receipt"))
    writer = Thread.new { @control.write("receipt") }
    await_waiting("receipt")
    assert_nil writer.join(0), "the effect exists while the response is held"

    command("release", "receipt")
    assert writer.join(1), "releasing the response must release its caller"
    assert_equal({ "count" => 1, "waiting" => 0 }, snapshot("receipt"))
    @control.write("receipt")
    assert_equal({ "count" => 2, "waiting" => 0 }, snapshot("receipt"),
      "the fixture exposes a duplicate call instead of deduplicating it")
  ensure
    command("release", "receipt")
    writer&.join(1)
    writer&.kill&.join
  end

  def test_releasing_another_marker_does_not_answer_the_held_call
    command("hold", "first")
    command("hold", "second")
    writer = Thread.new { @control.write("first") }
    await_waiting("first")

    command("release", "second")
    assert_nil writer.join(0)
    assert_equal({ "count" => 1, "waiting" => 1 }, snapshot("first"))
    assert_equal({ "count" => 0, "waiting" => 0 }, snapshot("second"))
  ensure
    command("release", "first")
    writer&.join(1)
    writer&.kill&.join
  end

  def test_an_unreleased_response_has_a_finite_bound
    @control = E2E::McpFixture::ControlledWrites.new(hold_seconds: 0)
    command("hold", "expired")

    assert_raises(E2E::McpFixture::ControlledWrites::HoldExpired) { @control.write("expired") }
    assert_equal({ "count" => 1, "waiting" => 0 }, snapshot("expired"))
  end

  def test_ordinary_mcp_requests_and_unarmed_writes_are_unchanged
    assert_nil @control.response("REQUEST_METHOD" => "POST", "PATH_INFO" => "/mcp")
    assert_nil @control.write("an ordinary unarmed note")
  end

  private

    def command(action, text)
      _, _, body = @control.response("REQUEST_METHOD" => "POST", "PATH_INFO" => "/fixture/writes/#{action}",
        "rack.input" => StringIO.new(JSON.generate("text" => text)))
      JSON.parse(body.join)
    end

    def snapshot(text)
      _, _, body = @control.response("REQUEST_METHOD" => "GET", "PATH_INFO" => "/fixture/writes",
        "QUERY_STRING" => URI.encode_www_form(text: text))
      JSON.parse(body.join)
    end

    def await_waiting(text)
      Timeout.timeout(1) do
        Thread.pass until snapshot(text).fetch("waiting") == 1
      end
      assert_equal 1, snapshot(text).fetch("count")
    end
end
