require "test_helper"
require "support/oauth_world"

class OauthCancellationTest < Minitest::Test
  include McpTest::OauthWorld
  include McpTest::Helpers

  def setup = oauth_setup
  def teardown = oauth_teardown

  def test_canceling_a_call_does_not_let_a_sibling_spend_its_in_flight_refresh_token
    cancellation_preserves_tokens
  end

  def test_a_reopened_connection_waits_for_the_old_providers_in_flight_refresh
    cancellation_preserves_tokens(reopen: true)
  end

  private

  def cancellation_preserves_tokens(reopen: false)
    login!
    connection = connection().tap(&:open!)
    previous_access = @storage.tokens.fetch("access_token")
    switch!("expire")

    entered = Queue.new
    releases = [Queue.new, Queue.new]
    lock = Mutex.new
    requests = 0
    original = @fixture.method(:token)
    @fixture.define_singleton_method(:token) do |request, base|
      index = lock.synchronize do
        requests += 1
        requests - 1
      end
      entered << index
      releases.fetch(index).pop
      original.call(request, base)
    end

    context = Rho::Runner::ExecutionContext.new(task_key: "first")
    first = Thread.new do
      Rho::Runner::ExecutionContext.with(context) do
        connection.call_tool("echo", { "text" => "first" }, public_name: "mcp__fxo__echo")
      end
    rescue StandardError => error
      error
    end
    assert_equal 0, entered.pop(timeout: 5), "the first request reached the real authorization server"
    context.cancel(:cancelled)
    assert first.join(5), "cancellation returns while the bounded HTTP request remains in flight"
    assert_kind_of Rho::Runner::ExecutionContext::Cancelled, first.value

    second = Thread.new do
      connection.open!(list: false) if reopen
      call(connection, "echo", { "text" => "second" })
    rescue StandardError => error
      error
    end
    overlapping = entered.pop(timeout: 1)
    releases.fetch(0) << :continue
    assert await { @storage.tokens&.fetch("access_token") != previous_access }, "the first refresh installed its valid pair"
    releases.fetch(1) << :continue
    assert second.join(5), "the sibling finishes after the refresh is released"

    refute_nil @storage.tokens, "a sibling must not clear the valid rotated pair with an invalid_grant from the spent token"
    assert_nil overlapping, "the canceled caller released the row mutex while its HTTP worker still held the refresh token"
    assert_equal "second", second.value.content
  ensure
    releases&.each { |release| release << :continue }
    first&.join(5)
    second&.join(5)
  end
end
