require "test_helper"
require_relative "support/contract_fixtures"
require "socket"

class PlatformDeploymentTest < Minitest::Test
  class ChunkTransport < CybrosAgentTest::FakeTransport
    def call(path, sink: nil, **options)
      response = super(path, **options)
      response.body.b.each_byte { |byte| sink.write(byte.chr) }
      response.with(body: nil)
    end
  end

  def pack = CybrosAgentTest::ContractFixtures.pack("platform_deployment.json")

  def client(script, transport_class: CybrosAgentTest::FakeTransport)
    @transport = transport_class.new(script)
    CybrosAgent::PlatformClient.new(base_url: "https://nexus.example", credential: "platform-key", transport: @transport)
  end

  def test_deployment_status_release_check_and_upgrade_preserve_the_server_receipt
    fixture = pack
    deployment = client([[200, {}, fixture.fetch("valid_state_fixture")],
      [200, {}, fixture.fetch("valid_state_fixture")],
      [202, { "Location" => "https://nexus.example/api/v1/admin/deployment/upgrades/operation" }, fixture.fetch("valid_upgrade_fixture")]])
      .deployment
    assert deployment.fetch.supported
    checked = deployment.check_release(tag: "v2", backup: false)
    candidate = { "release" => checked.candidate.release,
      "images" => checked.candidate.images.map { |image| image.to_h.transform_keys(&:to_s) } }
    accepted = deployment.upgrade(candidate:, backup: false, idempotency_key: "explicit-key")
    assert_equal 202, accepted.status
    assert_equal "https://nexus.example/api/v1/admin/deployment/upgrades/operation", accepted.location
    assert_equal "succeeded", accepted.upgrade.status
    assert_equal [:get, :post, :post], @transport.requests.map { |request| request.fetch(:method) }
    assert_equal 130, @transport.requests.fetch(1).fetch(:timeout)
    assert_equal({ "release_check" => { "tag" => "v2", "backup" => false } }, @transport.requests.fetch(1).fetch(:body))
    assert_equal({ "candidate" => candidate, "backup" => false }, @transport.requests.last.fetch(:body))
    assert_equal "explicit-key", @transport.requests.last.fetch(:headers).fetch("Idempotency-Key")
    assert_equal 30, @transport.requests.last.fetch(:timeout)
  end

  def test_upgrade_read_and_log_keep_unknown_status_and_opaque_cursor
    operation = client([[200, {}, pack.fetch("unknown_status_fixture")], [200, {}, pack.fetch("valid_log_fixture")]])
      .deployment.operation("operation/one")
    assert_equal "zz_unknown_value", operation.fetch.status
    log = operation.log(cursor: "opaque?cursor&one")
    assert_equal "fixture-cursor-1", log.next_cursor
    assert_equal "Complete", log.entries.first.text
    assert_equal "/api/v1/admin/deployment/upgrades/operation%2Fone/log", @transport.requests.last.fetch(:path)
    assert_equal({ "cursor" => "opaque?cursor&one" }, @transport.requests.last.fetch(:params))
  end

  def test_fragmented_sse_projects_known_events_and_preserves_future_events
    events = %w[valid_progress_event_fixture valid_error_event_fixture unknown_event_fixture].map { |name| pack.fetch(name) }
    wire = events.map do |event|
      id = event["id"] ? "id: #{event.fetch("id")}\r\n" : ""
      ": heartbeat\r\nunknown: ignored\r\nevent: #{event.fetch("event")}\r\n#{id}data: #{JSON.generate(event.fetch("data"))}\r\n\r\n"
    end.join
    operation = client([[200, {}, wire]], transport_class: ChunkTransport).deployment.operation("operation")
    received = []
    operation.stream(cursor: "query-cursor", last_event_id: "header-cursor") { |event| received << event }
    assert_equal 3, received.size
    assert_equal "succeeded", received.first.log.operation.status
    assert_equal "updater_unavailable", received.fetch(1).error.code
    assert_equal "zz_unknown_value", received.last.event
    assert_nil received.last.log
    assert_nil received.last.error
    assert_equal({ "future" => true }, received.last.data)
    assert_equal "future-cursor", received.last.id
    request = @transport.requests.first
    assert_equal "text/event-stream", request.fetch(:accept)
    assert_equal({ "cursor" => "query-cursor" }, request.fetch(:params))
    assert_equal "header-cursor", request.fetch(:headers).fetch("Last-Event-ID")
    assert_equal 1, @transport.requests.size
  end

  def test_stream_failure_and_consumer_failure_never_retry_or_start_an_upgrade
    operation = client([[503, {}, { "error" => { "code" => "updater_unavailable", "message" => "Unavailable" } }]])
      .deployment.operation("operation")
    error = assert_raises(CybrosAgent::Api::ServerError) { operation.stream { flunk "an HTTP error cannot yield events" } }
    assert_equal "updater_unavailable", error.code
    assert_equal 1, @transport.requests.size

    event = pack.fetch("valid_progress_event_fixture")
    wire = "event: #{event.fetch("event")}\ndata: #{JSON.generate(event.fetch("data"))}\n\n"
    operation = client([[200, {}, wire]]).deployment.operation("operation")
    error = assert_raises(RuntimeError) { operation.stream { raise "consumer failed" } }
    assert_equal "consumer failed", error.message
    assert_equal [:get], @transport.requests.map { |request| request.fetch(:method) }
  end

  def test_cr_terminated_stream_dispatches_only_a_complete_event_at_eof
    wire = "event: future\rdata: {\"complete\":true}\r\revent: future\rdata: {\"incomplete\":true}\r"
    operation = client([[200, {}, wire]], transport_class: ChunkTransport).deployment.operation("operation")
    received = []
    operation.stream { |event| received << event.data }
    assert_equal [{ "complete" => true }], received

    operation = client([[200, {}, "event: future\rdata: {}\r\r"]], transport_class: ChunkTransport).deployment.operation("operation")
    received = []
    operation.stream { |event| received << event.data }
    assert_equal [{}], received
  end

  def test_release_check_timeout_is_explicit_bounded_and_separate_from_body
    deployment = client([[200, {}, pack.fetch("valid_state_fixture")]]).deployment
    deployment.check_release(timeout: 150)
    request = @transport.requests.first
    assert_equal 150, request.fetch(:timeout)
    assert_equal({ "release_check" => {} }, request.fetch(:body))
    [0, -1, Float::INFINITY, Float::NAN].each do |timeout|
      assert_raises(ArgumentError) { deployment.check_release(timeout:) }
    end
    assert_equal 1, @transport.requests.size
  end

  def test_a_cli_authored_upgrade_has_no_actor_and_an_unfinished_backup_is_nullable
    body = pack.fetch("valid_upgrade_fixture")
    body["upgrade"] = body.fetch("upgrade").merge("actor_public_id" => nil, "database_backup" => nil)
    receipt = client([[200, {}, body]]).deployment.operation("operation").fetch
    assert_nil receipt.actor_public_id
    assert_nil receipt.database_backup
  end

  def test_native_http_transport_streams_the_platform_observation_with_its_credential
    event = pack.fetch("valid_progress_event_fixture")
    body = "event: #{event.fetch("event")}\nid: cursor-one\ndata: #{JSON.generate(event.fetch("data"))}\n\n"
    server = TCPServer.new("127.0.0.1", 0)
    serving = Thread.new do
      socket = server.accept
      request = []
      request << socket.gets until request.last == "\r\n"
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
      socket.write(body)
      request
    ensure
      socket&.close
    end
    platform = CybrosAgent::PlatformClient.new(base_url: "http://127.0.0.1:#{server.local_address.ip_port}",
      credential: "fixture-platform-token", request_timeout: 2)
    received = []
    platform.deployment.operation("operation").stream(cursor: "a/b", last_event_id: "older") { |item| received << item }
    request = serving.value.join
    assert_match %r{GET /api/v1/admin/deployment/upgrades/operation/stream\?cursor=a%2Fb HTTP/1.1}, request
    assert_match(/authorization: Bearer fixture-platform-token/i, request)
    assert_match(/accept: text\/event-stream/i, request)
    assert_match(/last-event-id: older/i, request)
    assert_equal ["cursor-one"], received.map(&:id)
    assert_equal "succeeded", received.first.log.operation.status
  ensure
    server&.close
    serving&.kill if serving&.alive?
    serving&.join
  end
end
