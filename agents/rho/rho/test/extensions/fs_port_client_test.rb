require "test_helper"
require "support/fs_port_double"

# THE DAEMON'S SIDE OF THE FILE-SYSTEM PORT: `Rho::Extensions::Environment::FsPort` speaks the
# runner gem's duck — `serves?`, `read_text`, `write_text` — over stdlib
# `Net::HTTP` to the loopback URL the surface registered through the
# door, with the bearer on every request. ONE error table: a 4xx with a
# code is the client's refusal (`not_found`, `beyond_eof`,
# `editor_refused`, an unknown code read as `editor_refused`), `cancelled`
# and the worker's own cancel signal are `Cancelled`, and everything that
# is not an answer — a refused connection, a timeout, a 5xx, a body that
# is not the shape — is `Unavailable`; the runner's `FsPort.ask` then
# calls `drop`, which tells the table's callback ONCE. Pinned against a
# scripted loopback server, as bytes.
class FsPortClientTest < Minitest::Test
  FsPort = Rho::Extensions::Environment::FsPort
  Duck = Rho::Runner::FsPort

  def setup
    @servers = []
    @dropped = []
  end

  def teardown
    @servers.each(&:close)
  end

  def server(&script)
    RhoTest::FsPortDouble.new(&script).tap { |double| @servers << double }
  end

  def port(double, read: true, write: true, client: "zed", **timeouts)
    FsPort.new(url: double.url, token: "secret-bearer", read: read, write: write, client: client,
      on_drop: ->(detail) { @dropped << detail }, **timeouts)
  end

  def test_the_flags_gate_each_method_and_the_description_never_carries_the_token
    double = server { |*| [200, { "text" => "" }] }

    both = port(double)
    assert both.serves?(:read)
    assert both.serves?(:write)
    refute both.serves?(:edit), "the duck names two methods; edit is the tool's own gate over both"
    read_only = port(double, write: false)
    assert read_only.serves?(:read)
    refute read_only.serves?(:write)
    assert_equal({ client: "zed", read: true, write: false }, read_only.describe)
    assert_equal "zed", read_only.client
    refute_includes read_only.inspect, "secret-bearer", "the bearer never rides an inspection"
    assert_kind_of Duck, read_only, "the runner's duck"

    same = { url: double.url, token: "secret-bearer", read: true, write: false, client: "zed" }
    assert read_only.same?(**same), "the registration's own tuple"
    [same.merge(token: "other"), same.merge(write: true), same.merge(client: "harbor"), same.merge(url: "#{double.url}/")].each do |other|
      refute read_only.same?(**other), other.reject { |key, _| key == :token }.inspect
    end
  end

  # THE READ: `POST /fs/read {path, line, limit}` with the bearer, the
  # answer's `text`; the write: `POST /fs/write {path, text}` → `{ok}`.
  def test_read_and_write_speak_the_two_shapes_with_the_bearer
    double = server do |path, body|
      case path
      when "/fs/read" then [200, { "text" => "line #{body.fetch("line")} of #{body.fetch("path")}\n" }]
      when "/fs/write" then [200, { "ok" => true }]
      else [404, { "error" => { "code" => "no_route", "message" => path } }]
      end
    end
    port = port(double)

    assert_equal "line 3 of /srv/app/a.rb\n", port.read_text("/srv/app/a.rb", line: 3, limit: 2)
    assert_nil port.write_text("/srv/app/b.rb", "new body\n")

    read, write = double.requests
    assert_equal "/fs/read", read.path
    assert_equal({ "path" => "/srv/app/a.rb", "line" => 3, "limit" => 2 }, read.body)
    assert_equal "Bearer secret-bearer", read.headers.fetch("authorization")
    assert_equal "application/json", read.headers.fetch("content-type")
    assert_equal "/fs/write", write.path
    assert_equal({ "path" => "/srv/app/b.rb", "text" => "new body\n" }, write.body)
    assert_equal "Bearer secret-bearer", write.headers.fetch("authorization")
    assert_empty @dropped
  end

  # THE CLIENT'S REFUSALS ride as the duck's errors: `not_found`,
  # `beyond_eof` and `cancelled` as their own, any other code as
  # `Refused` under that code (the editor said no). None drops the port.
  def test_a_4xx_with_a_code_is_the_ducks_error_for_that_code
    codes = %w[not_found beyond_eof editor_refused something_new cancelled]
    double = server { |_path, _body| [409, { "error" => { "code" => codes.shift, "message" => "the editor says no" } }] }
    port = port(double)

    assert_equal "the editor says no", assert_raises(Duck::NotFound) { port.read_text("/srv/a", line: 1, limit: 10) }.message
    assert_raises(Duck::BeyondEof) { port.read_text("/srv/a", line: 99, limit: 10) }
    refused = assert_raises(Duck::Refused) { port.write_text("/srv/a", "x") }
    assert_equal ["editor_refused", "the editor says no"], [refused.code, refused.message]
    assert_equal "something_new", assert_raises(Duck::Refused) { port.write_text("/srv/a", "x") }.code,
      "an unknown code is the editor refusing, under its own word"
    assert_raises(Duck::Cancelled) { port.write_text("/srv/a", "x") }
    assert_empty @dropped, "a refusal is an answer: the port stands"
    assert_equal({ "path" => "/srv/a", "line" => 1, "limit" => 10 }, double.requests.fetch(0).body)
  end

  # EDIT'S PRE-READ: both nil is the whole buffer — the wire carries the
  # path alone, no null fields.
  def test_a_read_with_no_window_sends_the_path_alone
    double = server { |*| [200, { "text" => "whole\n" }] }

    assert_equal "whole\n", port(double).read_text("/srv/a", line: nil, limit: nil)
    assert_equal({ "path" => "/srv/a" }, double.requests.fetch(0).body)
  end

  # NOT AN ANSWER: a 5xx (a JSON body, or a proxy's HTML — the status
  # names it either way), a body that is not JSON, a 200 without the
  # field, a 401 (the bearer is the surface's; a mismatch is a broken
  # port), a hung-up connection, a timeout and a refused connection —
  # each `Unavailable`, its message opening with the reason; the client
  # drops nothing itself (the runner's `ask` does), and `drop` tells the
  # table once however often it is called.
  def test_everything_that_is_not_an_answer_is_unavailable_and_drop_tells_the_table_once
    answers = [[500, { "error" => { "code" => "boom", "message" => "crashed" } }], [503, "<html>down</html>"], :garbage,
               [200, { "content" => "old shape" }], [401, { "error" => { "code" => "unauthorized", "message" => "bearer" } }],
               :close, :hang]
    double = server { |*| answers.shift }
    port = port(double, read_timeout: 0.2)

    labels = 7.times.map { assert_raises(Duck::Unavailable) { port.read_text("/srv/a", line: 1, limit: 1) }.message[/\A\w+/] }
    assert_equal %w[status_500 status_503 malformed malformed status_401 malformed timeout], labels
    assert_empty @dropped, "the client raises; the runner's ask drops"
    refute_predicate port, :dropped?

    refused = server { |*| [200, { "text" => "" }] }
    refused.close
    gone = port(refused)
    assert_equal "refused", assert_raises(Duck::Unavailable) { gone.write_text("/srv/a", "x") }.message[/\A\w+/]
    gone.drop("connection refused")
    gone.drop("again")
    assert_equal ["connection refused"], @dropped, "once"
    assert_predicate gone, :dropped?
  end

  # THE WORKER'S CANCEL SIGNAL ENDS THE SESSION: a read hanging on the
  # surface is cut the moment the context is cancelled, and the tool sees
  # `Cancelled`, not a 30 s wait.
  def test_the_contexts_cancel_signal_ends_a_hanging_session_at_once
    double = server { |*| :hang }
    port = port(double, read_timeout: 10)
    context = Rho::Runner::ExecutionContext.new

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Rho::Runner::ExecutionContext.with(context) do
      canceller = Thread.new do
        sleep 0.2
        context.cancel
      end
      assert_raises(Duck::Cancelled) { port.read_text("/srv/a", line: 1, limit: 1) }
      canceller.join
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5, "the session ended with the signal"
    assert_empty @dropped, "a cancel is the runner's, not the port's failure"
  end

  # THE CLOCKS: 2 s to open, 30 s for a read, 60 s for a write —
  # the write's is longer because an editor formats on save.
  def test_the_defaults_are_the_designs_clocks
    assert_equal [2, 30, 60], [FsPort::OPEN_TIMEOUT_SECONDS, FsPort::READ_TIMEOUT_SECONDS, FsPort::WRITE_TIMEOUT_SECONDS]
  end
end
