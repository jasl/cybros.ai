require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects with a usable session cookie" do
    session = create_browser_session(identities(:member))
    cookies.signed[:session_id] = session.public_id

    connect

    assert_equal users(:member), connection.current_user
  end

  # THE AGENT'S OWN CABLE AUTH, which had no test at all: the bearer branch is
  # how every non-browser consumer identifies, and it is the only branch the
  # OneShot channel accepts (a cookie connection carries no member credential
  # and that channel rejects it).
  test "connects with a member bearer credential and remembers which one" do
    token = create_access_token_fixture(user: users(:member), name: "Cable")

    connect headers: { "Authorization" => "Bearer #{token.secret}" }

    assert_equal users(:member), connection.current_user
    assert_equal token.token, connection.current_access_token
  end

  test "periodically rechecks bearer authority outside the heartbeat caller" do
    token = create_access_token_fixture(user: users(:member), name: "Cable periodic")
    connect headers: { "Authorization" => "Bearer #{token.secret}" }

    queued = []
    connection.define_singleton_method(:perform_work) do |receiver, method, *arguments|
      queued << [receiver, method, arguments]
    end
    connection.define_singleton_method(:transmit) { |*| }

    connection.beat
    assert_empty queued

    travel ApplicationCable::Connection::AUTHORITY_CHECK_INTERVAL + 1.second do
      connection.beat
    end

    assert_equal [[connection, :verify_current_authority, []]], queued
  end

  test "the periodic authority check closes a revoked bearer connection" do
    token = create_access_token_fixture(user: users(:member), name: "Cable revoked")
    connect headers: { "Authorization" => "Bearer #{token.secret}" }
    AccessToken.where(id: token.token.id).update_all(revoked_at: Time.current)

    closed_with = nil
    connection.define_singleton_method(:close) { |**options| closed_with = options }
    connection.verify_current_authority

    assert_equal false, closed_with.fetch(:reconnect)
    assert_equal "unauthorized", closed_with.fetch(:reason)
  end

  # THE EXECUTOR'S CABLE IDENTITY: a transport bearer identifies the executor token and NEVER a user
  # — an executor socket carries no member standing, so the member feeds reject it for free.
  test "connects with a transport bearer and identifies the executor token, never a user" do
    transport = create_bound_credential(executor: task_executors(:address), name: "Cable transport")

    connect headers: { "Authorization" => "Bearer #{transport.secret}" }

    assert_nil connection.current_user
    assert_nil connection.current_access_token
    assert_equal transport.token, connection.current_executor_token
    assert_nil connection.verified_member_access_token, "no member standing rides an executor socket"
    assert_equal transport.token, connection.verified_executor_token
  end

  test "the periodic check closes the executor socket after a re-pair, and after a revoke" do
    executor = task_executors(:address)
    transport = create_bound_credential(executor: executor, name: "Cable epoch")
    connect headers: { "Authorization" => "Bearer #{transport.secret}" }
    closed_with = nil
    connection.define_singleton_method(:close) { |**options| closed_with = options }

    connection.verify_current_authority
    assert_nil closed_with, "the credential is still usable"

    executor.re_pair(display_name: "again")
    connection.verify_current_authority
    assert_equal false, closed_with.fetch(:reconnect)
    assert_equal "unauthorized", closed_with.fetch(:reason)

    closed_with = nil
    revoked = create_bound_credential(executor: executor, name: "Cable revoked")
    connect headers: { "Authorization" => "Bearer #{revoked.secret}" }
    connection.define_singleton_method(:close) { |**options| closed_with = options }
    executor.revoke
    connection.verify_current_authority
    assert_equal "unauthorized", closed_with.fetch(:reason)
  end

  test "Agent removal fences new executor sockets and closes an existing one on authority recheck" do
    transport = create_bound_credential(executor: task_executors(:address))
    connect headers: { "Authorization" => "Bearer #{transport.secret}" }
    users(:agent).remove

    closed_with = nil
    connection.define_singleton_method(:close) { |**options| closed_with = options }
    connection.verify_current_authority
    assert_equal "unauthorized", closed_with.fetch(:reason)
    assert_equal false, closed_with.fetch(:reconnect)
    assert_reject_connection do
      connect headers: { "Authorization" => "Bearer #{transport.secret}" }
    end
  end

  test "the heartbeat schedules the authority recheck for an executor socket too" do
    transport = create_bound_credential(executor: task_executors(:address), name: "Cable beat")
    connect headers: { "Authorization" => "Bearer #{transport.secret}" }
    queued = []
    connection.define_singleton_method(:perform_work) { |receiver, method, *arguments| queued << [receiver, method, arguments] }
    connection.define_singleton_method(:transmit) { |*| }

    travel ApplicationCable::Connection::AUTHORITY_CHECK_INTERVAL + 1.second do
      connection.beat
    end

    assert_equal [[connection, :verify_current_authority, []]], queued
  end

  # THE PONG EXPECTATION (r-modes M4): an executor socket that stops
  # answering the server's pings is torn down — COUNT-based, so a stalled
  # server (which sends no pings either) cannot mass-disconnect every
  # executor when it resumes — with `reconnect: true`, so the SDK client
  # comes back and the channel's `unsubscribed` edge clears the mark.
  test "an executor socket that stops ponging is closed after PONG_MISSES pings with reconnect: true" do
    connection = executor_connection("Cable pong misses")
    connection.expect_pongs

    ApplicationCable::Connection::PONG_MISSES.times { connection.beat }
    assert_nil @closed_with, "every ping up to the limit is still a chance to answer"

    connection.beat
    assert_equal({ reason: "pong_timeout", reconnect: true }, @closed_with)
  end

  test "a ponging executor socket stays open" do
    connection = executor_connection("Cable pong")
    connection.expect_pongs

    ApplicationCable::Connection::PONG_MISSES.times { connection.beat }
    connection.pong
    ApplicationCable::Connection::PONG_MISSES.times { connection.beat }
    assert_nil @closed_with, "a pong resets the count"

    connection.beat
    assert_equal "pong_timeout", @closed_with.fetch(:reason)
  end

  # A connection that has not subscribed cannot answer (the pong is a
  # channel action) and must not be closed for it.
  test "an executor socket without an inbox subscription is never pong-checked" do
    connection = executor_connection("Cable unsubscribed")

    (ApplicationCable::Connection::PONG_MISSES * 3).times { connection.beat }

    assert_nil @closed_with
    assert_not connection.pongs_expected?
  end

  test "a member socket is never pong-checked" do
    token = create_access_token_fixture(user: users(:member), name: "Cable member pong")
    connect headers: { "Authorization" => "Bearer #{token.secret}" }
    silence_beat(connection)

    (ApplicationCable::Connection::PONG_MISSES * 3).times { connection.beat }

    assert_nil @closed_with
  end

  test "rejects a bearer credential that does not resolve" do
    assert_reject_connection { connect headers: { "Authorization" => "Bearer sk-nope" } }
  end

  test "rejects without a session cookie" do
    assert_reject_connection { connect }
  end

  test "rejects a fenced session" do
    session = create_browser_session(identities(:member))
    cookies.signed[:session_id] = session.public_id
    users(:member).increment!(:authority_generation)

    assert_reject_connection { connect }
  end

  private

    # A connected executor socket whose ping, authority recheck and close are
    # captured: `transmit` swallowed, `perform_work` dropped, `close` recorded
    # in @closed_with.
    def executor_connection(name)
      transport = create_bound_credential(executor: task_executors(:address), name: name)
      connect headers: { "Authorization" => "Bearer #{transport.secret}" }
      silence_beat(connection)
      connection
    end

    def silence_beat(connection)
      @closed_with = nil
      connection.define_singleton_method(:perform_work) { |*| }
      connection.define_singleton_method(:transmit) { |*| }
      test = self
      connection.define_singleton_method(:close) { |**options| test.instance_variable_set(:@closed_with, options) }
    end
end
