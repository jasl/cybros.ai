require "test_helper"
require "net/http"
require "json"

# THE FILE-SYSTEM PORT'S SURFACE HALF: the
# two routes against an in-process client double — the 200 shapes, each
# error code of the table, the bearer refusal 401, the timeout's
# `$/cancel_request`, `cancelled` — and the registration through
# `Core#bind_environment` at new, re-asserted per prompt, dropped on close.
class AcpFsPortTest < Minitest::Test
  Methods = Rho::Acp::Methods
  SNAPSHOT = ["snapshot", { "turn" => "trn_1", "run_public_id" => "alp_1" }].freeze
  COMPLETED = ["turn_status", { "turn_public_id" => "trn_1", "run_public_id" => "alp_1", "status" => "completed", "run_status" => "completed" }].freeze
  CLOSED = ["closed", {}].freeze

  def setup
    @core = RhoAcpTest::CoreDouble.new
    @seen = []
    @answer = ->(inbound) { inbound.respond("content" => "buffer text\n") }
    @harness = RhoAcpTest::AgentHarness.new(core: @core)
    @harness.policy = lambda do |inbound|
      @seen << [inbound.method, inbound.params]
      @answer.call(inbound)
    end
  end

  def teardown
    @harness.close
  end

  def open(read: true, write: true)
    @harness.initialize_agent(capabilities: RhoAcpTest::AgentHarness.capabilities(read: read, write: write))
    @harness.new_session(cwd: "/work/project")
    @registration = @core.calls_of(:bind_environment).find { |_args, kwargs| kwargs.key?(:fs) }.last[:fs]
    @port = @harness.agent.fs_port
  end

  def post(route, body, bearer: @registration["token"])
    uri = URI.parse("#{@registration["url"]}#{route}")
    request = Net::HTTP::Post.new(uri.path)
    request["Authorization"] = "Bearer #{bearer}" if bearer
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 2, read_timeout: 10) { |http| http.request(request) }
    [response.code.to_i, JSON.parse(response.body)]
  end

  def test_the_registration_names_the_loopback_url_the_bearer_the_flags_and_the_client
    open(read: true, write: false)

    assert_match %r{\Ahttp://127\.0\.0\.1:\d+\z}, @registration["url"]
    assert_match(/\A[0-9a-f]{64}\z/, @registration["token"])
    assert_equal({ "read" => true, "write" => false, "client" => "test-editor" }, @registration.slice("read", "write", "client"))
  end

  def test_a_read_relays_the_path_the_line_and_the_limit_and_answers_the_text
    open
    status, body = post("/fs/read", { "path" => "/work/project/a.rb", "line" => 3, "limit" => 10 })

    assert_equal [200, { "text" => "buffer text\n" }], [status, body]
    assert_equal [[Methods::FS_READ_TEXT_FILE, { "sessionId" => "cnv_1", "path" => "/work/project/a.rb", "line" => 3, "limit" => 10 }]], @seen
  end

  def test_a_whole_read_sends_no_window
    open
    post("/fs/read", { "path" => "/work/project/a.rb" })

    assert_equal({ "sessionId" => "cnv_1", "path" => "/work/project/a.rb" }, @seen.first.last)
  end

  def test_a_write_relays_the_content_and_answers_ok
    @answer = ->(inbound) { inbound.respond({}) }
    open
    status, body = post("/fs/write", { "path" => "/work/project/a.rb", "text" => "new\n" })

    assert_equal [200, { "ok" => true }], [status, body]
    assert_equal [[Methods::FS_WRITE_TEXT_FILE, { "sessionId" => "cnv_1", "path" => "/work/project/a.rb", "content" => "new\n" }]], @seen
  end

  def test_the_error_table
    open
    {
      [-32002, "no such buffer"] => [404, "not_found"],
      [-32602, "line past the end"] => [422, "beyond_eof"],
      [-32800, "Request cancelled"] => [409, "cancelled"],
      [-32603, "the editor refused"] => [422, "editor_refused"],
      [-32000, "auth"] => [422, "editor_refused"],
    }.each do |(code, message), (status, expected)|
      @answer = ->(inbound) { inbound.fail(code, message) }
      got_status, body = post("/fs/read", { "path" => "/work/project/a.rb" })
      assert_equal [status, expected, message], [got_status, body.dig("error", "code"), body.dig("error", "message")], code.to_s
    end
  end

  def test_an_empty_answer_past_the_first_line_is_beyond_eof
    @answer = ->(inbound) { inbound.respond("content" => "") }
    open
    status, body = post("/fs/read", { "path" => "/work/project/a.rb", "line" => 2 })
    assert_equal [422, "beyond_eof"], [status, body.dig("error", "code")]

    status, body = post("/fs/read", { "path" => "/work/project/a.rb", "line" => 1 })
    assert_equal [200, ""], [status, body["text"]]
  end

  def test_a_wrong_or_missing_bearer_is_401_and_nothing_reaches_the_editor
    open
    assert_equal 401, post("/fs/read", { "path" => "/x" }, bearer: "0" * 64).first
    assert_equal 401, post("/fs/read", { "path" => "/x" }, bearer: nil).first
    assert_empty @seen
  end

  def test_a_body_without_a_path_or_with_a_non_string_text_is_400
    open
    assert_equal [400, "malformed_body"], post("/fs/read", {}).then { |status, body| [status, body.dig("error", "code")] }
    assert_equal [400, "malformed_body"], post("/fs/write", { "path" => "/x", "text" => 3 }).then { |status, body| [status, body.dig("error", "code")] }
  end

  def test_a_flag_the_client_did_not_advertise_is_editor_refused
    open(read: true, write: false)
    status, body = post("/fs/write", { "path" => "/x", "text" => "t" })

    assert_equal [422, "editor_refused"], [status, body.dig("error", "code")]
    assert_empty @seen
  end

  def test_the_timeout_sends_cancel_request_and_answers_504
    @harness.policy = :hold
    open
    @port.read_wait = 0.3
    status, body = post("/fs/read", { "path" => "/work/project/a.rb" })
    held = @harness.await_held

    assert_equal [504, "timeout"], [status, body.dig("error", "code")]
    assert held.cancelled?, "no $/cancel_request reached the client"
  end

  def test_the_registration_is_reasserted_per_prompt_and_dropped_on_close
    @core.events["cnv_1"] = [[SNAPSHOT, COMPLETED, CLOSED]]
    open
    @harness.prompt("cnv_1", "go")
    fs_binds = @core.calls_of(:bind_environment).select { |_args, kwargs| kwargs.key?(:fs) }
    assert_equal 2, fs_binds.length
    assert_equal fs_binds.first.last[:fs], fs_binds.last.last[:fs]

    @harness.request(Methods::SESSION_CLOSE, { "sessionId" => "cnv_1" })
    drops = @core.calls_of(:bind_environment).select { |_args, kwargs| kwargs.key?(:fs) && kwargs[:fs].nil? }
    assert_equal [[["cnv_1"], { fs: nil }]], drops
  end

  def test_no_port_is_started_or_registered_without_the_capability
    @harness.initialize_agent
    @harness.new_session(cwd: "/tmp")

    assert_nil @harness.agent.fs_port
    refute @core.calls_of(:bind_environment).any? { |_args, kwargs| kwargs.key?(:fs) }
  end

  def test_a_runner_elsewhere_refusal_is_logged_and_the_session_continues
    @core.refuse(:bind_fs, "cnv_1 runs on exr_9: a port is this daemon's loopback endpoint", code: "runner_elsewhere", status: 409)
    open

    assert_equal "cnv_1", @harness.agent.sessions["cnv_1"].id
    assert_includes @harness.stderr, "runs on exr_9"
  end
end
