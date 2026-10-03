$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/mcp"
require "fileutils"
require "json"
require "tmpdir"
require "minitest/autorun"
require_relative "support/rho_state"
require_relative "support/fake_transport"

module McpTest
  GEMFILE = File.expand_path("../Gemfile", __dir__)
  FIXTURE_SERVER = File.expand_path("support/fixture_server.rb", __dir__)

  # A row for the real fixture server, launched `bundle exec ruby` under
  # THIS gem's Gemfile in the row's `env` — the daemon's child env drops
  # Bundler's trail (`ChildEnv`), so a bare `ruby` would resolve `mcp` as
  # a system gem it does not have. `FX_TOKEN` rides as the scrub pin.
  def self.real_row(key: "fx", tools: "*", args: [], timeout_ms: nil, startup_timeout_ms: 30_000, extra_env: {})
    raw = {
      "transport" => "stdio", "command" => Gem.ruby,
      "args" => [Gem.bin_path("bundler", "bundle"), "exec", "ruby", FIXTURE_SERVER, *args],
      "env" => { "BUNDLE_GEMFILE" => GEMFILE, "FX_TOKEN" => "${FX_TOKEN}" }.merge(extra_env),
      "tools" => tools, "startup_timeout_ms" => startup_timeout_ms,
    }
    raw["timeout_ms"] = timeout_ms if timeout_ms
    Rho::Mcp::Settings.parse({ key => raw }, env: { "FX_TOKEN" => FX_TOKEN }, home: Dir.tmpdir).fetch(0)
  end

  FX_TOKEN = "fx-secret-token-0123456789".freeze

  # The stdio transport a real row connects through: the module's own
  # factory, over the SCRUBBED child environment with the row's `env`.
  def self.real_transport_factory
    lambda do |row, read_timeout:, oauth: nil|
      Rho::Mcp::StdioTransport.new(command: row.command, args: row.args, env: Rho::Mcp.child_env(row), cwd: row.cwd,
        read_timeout: read_timeout, stop_stage: 1.0)
    end
  end

  module Helpers
    def with_tool_env
      Dir.mktmpdir("rho-mcp-test") do |root|
        real = File.realpath(root)
        env = Rho::Runner::ToolEnv.new(root: real, artifacts_dir: File.join(real, ".artifacts"))
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) { yield(env, real) }
      end
    end

    def process_group_alive?(pgid)
      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def await(seconds: 10, every: 0.05)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        value = yield
        return value if value
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end
  end
end
