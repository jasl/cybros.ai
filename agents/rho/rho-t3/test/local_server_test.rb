require_relative "test_helper"
require "rbconfig"

class LocalServerTest < Minitest::Test
  include T3Test

  def test_the_service_owns_one_foreground_group_and_closes_it_on_shutdown
    Dir.mktmpdir do |root|
      native = Rho::T3::NativeEnvironment.new(root: File.join(root, "plugin"), work_root: File.join(root, "work"))
      port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
      script = File.join(root, "service.rb")
      File.write(script, <<~RUBY)
        require "socket"
        require "json"
        File.write(File.join(Dir.pwd, "started.json"), JSON.generate({ "pid" => Process.pid, "argv" => ARGV,
          "codex_home" => ENV.fetch("CODEX_HOME"), "claude_home" => ENV.fetch("CLAUDE_CONFIG_DIR") }))
        socket = TCPServer.new("127.0.0.1", Integer(ARGV.fetch(ARGV.index("--port") + 1)))
        sleep
      RUBY
      server = Rho::T3::LocalServer.new(settings: settings(server: "local", listen_port: port), native: native)
      original = Rho::Runner::OwnedProcess.method(:spawn)
      spawn = ->(env, _program, *args, **options) { original.call(env, RbConfig.ruby, script, *args, **options) }
      Rho::Runner::OwnedProcess.singleton_class.send(:remove_method, :spawn)
      Rho::Runner::OwnedProcess.define_singleton_method(:spawn, spawn)
      begin
        server.start
        assert server.running?
        first = JSON.parse(File.read(File.join(native.work_root, "started.json")))
        server.start
        assert_equal first, JSON.parse(File.read(File.join(native.work_root, "started.json")))
        assert_equal native.codex_root, first.fetch("codex_home")
        assert_equal native.claude_root, first.fetch("claude_home")
        assert_includes first.fetch("argv"), native.server_root
        server.stop
        refute server.running?
        assert_raises(Errno::ESRCH) { Process.kill(0, first.fetch("pid")) }
        server.stop
      ensure
        server.stop
        Rho::Runner::OwnedProcess.singleton_class.send(:remove_method, :spawn)
        Rho::Runner::OwnedProcess.define_singleton_method(:spawn, original)
      end
    end
  end

  def test_an_existing_listener_is_not_adopted_or_stopped
    Dir.mktmpdir do |root|
      TCPServer.open("127.0.0.1", 0) do |socket|
        native = Rho::T3::NativeEnvironment.new(root: root, work_root: File.join(root, "work"))
        server = Rho::T3::LocalServer.new(settings: settings(server: "local", listen_port: socket.addr[1]), native: native)
        error = assert_raises(Rho::T3::Error) { server.start }
        assert_includes error.message, "already in use"
        refute socket.closed?
      end
    end
  end
end
