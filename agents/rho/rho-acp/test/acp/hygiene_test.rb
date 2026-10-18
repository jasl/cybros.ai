require "test_helper"
require "open3"
require "json"
require "tmpdir"

# DISPATCH AND HYGIENE: under the surface a child
# spawned with an inherited stdout, a `puts`, a `warn` and `$stdout` all
# land on stderr — the wire IO is the one holder of fd 1 — and through
# the real exe one line in is one line out for `initialize`, stderr
# carrying the rest; EOF exits 0.
class AcpHygieneTest < Minitest::Test
  ROOT = RhoAcpTest::ROOT
  ENV_FOR = RhoAcpTest::CHILD_BUNDLE_ENV

  def test_a_child_with_an_inherited_stdout_never_reaches_the_wire
    script = File.join(Dir.mktmpdir("rho-acp-hygiene"), "leak.rb")
    File.write(script, <<~RUBY)
      $LOAD_PATH.unshift(#{File.join(ROOT, "lib").inspect})
      require "rho/acp"
      wire = Rho::Acp::Wire.over_stdio
      system("echo leaked-by-child")
      puts "leaked-by-puts"
      $stdout.puts "leaked-by-dollar-stdout"
      STDOUT.puts "leaked-by-STDOUT"
      warn "on-stderr"
      wire.write_result(1, { "ok" => true })
    RUBY
    stdout, stderr, status = Open3.capture3(ENV_FOR, Gem.ruby, "-rbundler/setup", script, chdir: ROOT)

    assert_equal 0, status.exitstatus, stderr
    assert_equal [{ "jsonrpc" => "2.0", "id" => 1, "result" => { "ok" => true } }], stdout.lines.map { |line| JSON.parse(line) }
    %w[leaked-by-child leaked-by-puts leaked-by-dollar-stdout leaked-by-STDOUT on-stderr].each do |leak|
      assert_includes stderr, leak
    end
  end

  # An editor keeps stdin open while it waits: one line in, one line out,
  # per request; then EOF, exit 0.
  def test_through_the_exe_one_line_in_is_one_line_out_and_eof_exits_0
    home = Dir.mktmpdir("rho-acp-home")
    stderr_path = File.join(home, "stderr.log")
    env = ENV_FOR.merge("RHO_HOME" => home, "RHO_NEXUS_URL" => "https://nexus.example")
    io = IO.popen(env, [Gem.ruby, "-rbundler/setup", RhoAcpTest::EXE, "--mode", "ask"], "r+", err: [stderr_path, "w"], chdir: ROOT)
    io.set_encoding(Encoding::UTF_8)
    answers = [
      { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => { "protocolVersion" => 1, "clientCapabilities" => {} } },
      { "jsonrpc" => "2.0", "id" => 2, "method" => "session/new", "params" => { "cwd" => home, "mcpServers" => [] } },
      { "jsonrpc" => "2.0", "id" => 3, "method" => "session/list", "params" => {} },
    ].map do |frame|
      io.puts(JSON.generate(frame))
      io.flush
      line = io.gets
      refute_nil line, "the exe answered nothing to #{frame["method"]} (#{File.read(stderr_path)})"
      JSON.parse(line)
    end
    io.close_write
    assert_nil io.gets, "a line after EOF"
    io.close

    assert_equal 0, $?.exitstatus, File.read(stderr_path)
    by_id = answers.to_h { |line| [line["id"], line] }
    assert_equal 1, by_id[1].dig("result", "protocolVersion")
    refute_empty by_id[1].dig("result", "authMethods")
    assert_equal(-32603, by_id[2].dig("error", "code"))
    assert_equal "no local daemon is running; start one with `rho server`", by_id[2].dig("error", "message")
    assert_equal(-32601, by_id[3].dig("error", "code"))
  end
end
