require "minitest/autorun"
require "tmpdir"
require_relative "../updater"

class UpdaterTransportTest < Minitest::Test
  class TestEngine
    attr_reader :requests

    def initialize
      @requests = Queue.new
    end

    def call(request)
      @requests.push(request)
      { "status" => 200, "data" => { "supported" => true, "candidate" => nil } }
    end
  end

  def setup
    @directory = Dir.mktmpdir("cu-", "/tmp")
    @socket_path = File.join(@directory, "ipc", "updater.sock")
    @engine = TestEngine.new
    @server = CybrosUpdater::Server.new(engine: @engine, socket_path: @socket_path, group: Process.gid)
    @thread = Thread.new do
      @server.run
    rescue IOError, Errno::EBADF
      nil
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until File.socket?(@socket_path)
      raise "Server did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.001
    end
    @client = CybrosUpdater::Client.new(@socket_path)
  end

  def teardown
    @server.close
    @thread.join
    FileUtils.remove_entry(@directory)
  end

  def test_real_unix_socket_round_trip_and_private_permissions
    assert_equal 200, @client.call("operation" => "status").fetch("status")
    assert_equal "status", @engine.requests.pop.fetch("operation")
    assert_equal 0o660, File.stat(@socket_path).mode & 0o777
    assert_equal 0o750, File.stat(File.dirname(@socket_path)).mode & 0o777
  end

  def test_malformed_and_oversized_messages_do_not_dispatch
    socket = UNIXSocket.new(@socket_path)
    socket.write("malformed private data\n")
    response = JSON.parse(socket.gets)
    assert_equal "invalid_request", response.dig("error", "code")
    refute_includes JSON.generate(response), "private data"
    socket.close
    socket = UNIXSocket.new(@socket_path)
    socket.write("x" * (CybrosUpdater::REQUEST_LIMIT + 1))
    response = JSON.parse(socket.gets)
    assert_equal 400, response.fetch("status")
    assert @engine.requests.empty?
    socket.close
  end

  def test_client_enforces_size_limit_and_unavailable_socket_errors
    error = assert_raises(CybrosUpdater::Error) { @client.call("operation" => "status", "extra" => "x" * CybrosUpdater::REQUEST_LIMIT) }
    assert_equal "invalid_request", error.code
    missing = CybrosUpdater::Client.new(File.join(@directory, "missing.sock"))
    assert_equal "updater_unavailable", assert_raises(CybrosUpdater::Error) { missing.call("operation" => "status") }.code
  end

  def test_slow_incomplete_request_has_a_bounded_transport_deadline
    reader, writer = UNIXSocket.pair
    writer.write("{")
    error = assert_raises(CybrosUpdater::Error) { CybrosUpdater::Transport.read_line(reader, limit: 100, timeout: 0.02) }
    assert_equal "updater_unavailable", error.code
  ensure
    reader&.close
    writer&.close
  end

  def test_disconnected_request_observer_does_not_break_following_requests
    socket = UNIXSocket.new(@socket_path)
    socket.write("{\"operation\":\"status\"}\n")
    socket.close
    assert_equal "status", @engine.requests.pop.fetch("operation")
    assert_equal 200, @client.call("operation" => "status").fetch("status")
  end
end
