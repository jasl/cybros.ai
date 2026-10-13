require "minitest/autorun"
require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require_relative "../support/fs_port_server"

# THE SCRIPTED FILE-SYSTEM PORT PINNED AS A WIRE: `E2E::FsPortServer` speaks the two shapes rho's
# client speaks — a windowed read of an in-memory buffer, a write that lands in the buffer and on
# the mirror — checks the bearer, answers the editor's codes by name, and turns its modes. No world,
# no daemon: a loopback socket in this process, so a defect here is a red here and not a diagnosis
# at the end of a world.
class FsPortServerTest < Minitest::Test
  def setup
    @mirror = Dir.mktmpdir("fs-port-mirror")
    @server = E2E::FsPortServer.new(mirror: @mirror, delay: 0.3).start
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@mirror)
  end

  def post(path, body, token: @server.token)
    uri = URI.join(@server.url, path)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) { |http| http.request(request) }
    [response.code.to_i, JSON.parse(response.body)]
  end

  def test_a_read_is_a_window_of_the_buffer_and_the_editors_codes_ride_by_name
    @server.set_buffer("/srv/app/draft.txt", "one\ntwo\nthree\n")

    assert_equal [200, { "text" => "two\nthree\n" }], post("/fs/read", { "path" => "/srv/app/draft.txt", "line" => 2, "limit" => 5 })
    assert_equal [200, { "text" => "one\n" }], post("/fs/read", { "path" => "/srv/app/draft.txt", "line" => 1, "limit" => 1 })
    code, body = post("/fs/read", { "path" => "/srv/app/draft.txt", "line" => 4, "limit" => 1 })
    assert_equal [409, "beyond_eof"], [code, body.dig("error", "code")]
    code, body = post("/fs/read", { "path" => "/srv/app/other.txt", "line" => 1, "limit" => 1 })
    assert_equal [404, "not_found"], [code, body.dig("error", "code")]
    code, body = post("/fs/read", { "path" => "/srv/app/draft.txt", "line" => 1, "limit" => 1 }, token: "wrong")
    assert_equal [401, "unauthorized"], [code, body.dig("error", "code")]
    assert_equal [404, "no_route"], post("/fs/list", {}).then { |c, b| [c, b.dig("error", "code")] }
    assert_equal ["POST /fs/read", "POST /fs/read", "POST /fs/read", "POST /fs/read", "POST /fs/read", "POST /fs/list"],
      @server.requests.map(&:path)
    assert_equal({ "path" => "/srv/app/draft.txt", "line" => 2, "limit" => 5 }, @server.requests.fetch(0).body)
  end

  def test_a_write_lands_in_the_buffer_and_on_the_mirror_and_refuse_is_the_editors_no
    assert_equal [200, { "ok" => true }], post("/fs/write", { "path" => "/srv/app/new.txt", "text" => "fresh\n" })
    assert_equal "fresh\n", @server.buffers.fetch("/srv/app/new.txt")
    assert_equal "fresh\n", File.read(@server.mirror_path("/srv/app/new.txt"), encoding: Encoding::UTF_8)
    assert_equal File.join(@mirror, "srv/app/new.txt"), @server.mirror_path("/srv/app/new.txt")

    @server.mode = "refuse"
    code, body = post("/fs/write", { "path" => "/srv/app/new.txt", "text" => "again\n" })
    assert_equal [409, "editor_refused"], [code, body.dig("error", "code")]
    assert_equal "fresh\n", @server.buffers.fetch("/srv/app/new.txt"), "nothing changed on a refusal"
    assert_equal [200, { "text" => "fresh\n" }], post("/fs/read", { "path" => "/srv/app/new.txt", "line" => 1, "limit" => 9 }),
      "reads still serve under refuse"
  end

  def test_beyond_eof_slow_and_die_turn_the_wire
    @server.set_buffer("/srv/a", "x\n")
    @server.mode = "beyond_eof"
    code, body = post("/fs/read", { "path" => "/srv/a", "line" => 1, "limit" => 1 })
    assert_equal [409, "beyond_eof"], [code, body.dig("error", "code")]

    @server.mode = "slow"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal 200, post("/fs/read", { "path" => "/srv/a", "line" => 1, "limit" => 1 }).first
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.3, "the answer waited the delay"

    @server.mode = "die"
    assert_raises(Errno::ECONNREFUSED) { post("/fs/read", { "path" => "/srv/a", "line" => 1, "limit" => 1 }) }
    assert_raises(ArgumentError) { @server.mode = "explode" }
  end
end
