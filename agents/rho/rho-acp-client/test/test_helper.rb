$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/acp-client"
# rho's whole test support tree — `RhoTest.host` (the host a loader hands
# an extension without booting a daemon), `RhoTest::CliHarness`,
# `NexusDoubles`, minitest — by relative path: one implementation of the
# scripted daemons, shared with the gem the tool will run under. rho's
# helper resolves its own `lib` by its own `__dir__`.
require_relative "../../rho/test/test_helper"
require "stringio"

module RhoAcpClientTest
  ROOT = File.expand_path("..", __dir__)
  # THE SCRIPTED AGENT: the harness's stdlib-only
  # fixture, spawned by path under the scrubbed child environment — no
  # bundle, so `Gem.ruby` alone runs it.
  AGENT = File.expand_path("../../../../e2e/support/acp_fixture/agent.rb", __dir__)
  # This gem's own bundle for any child a test spawns, all three names:
  # Bundler's `bundle exec` exports `BUNDLE_LOCKFILE` beside
  # `BUNDLE_GEMFILE`, and a child that inherits one while naming another
  # resolves the wrong bundle and writes it over the wrong lockfile.
  CHILD_BUNDLE_ENV = {
    "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
    "BUNDLE_LOCKFILE" => File.join(ROOT, "Gemfile.lock"),
    "BUNDLE_FROZEN" => "true",
  }.freeze
  SECRET = "fixture-secret-value-0123456789".freeze

  # A raw `acp_agents` row launching the fixture in one of its modes.
  def self.raw_row(mode, description: "the #{mode} fixture agent", **extra)
    { "command" => Gem.ruby, "args" => [AGENT, "--mode", mode], "description" => description }.merge(extra)
  end

  def self.row(mode, key: mode.tr("_", "-"), env: {}, **extra)
    Rho::AcpClient::Settings.parse({ key => raw_row(mode, **extra) }, env: env).fetch(0)
  end

  # A tool environment over a throwaway root, and the worker-thread
  # context a tool call runs under — `conversation_public_id` is what the
  # children table keys a child by.
  module Helpers
    def with_tool_env(conversation: "conv-1", task_key: "r1t0", deadline: nil)
      Dir.mktmpdir("rho-acp-client-test") do |root|
        real = File.realpath(root)
        env = Rho::Runner::ToolEnv.new(root: real, artifacts_dir: File.join(real, ".artifacts"))
        context = Rho::Runner::ExecutionContext.new(conversation_public_id: conversation, task_key: task_key,
          agent_loop_public_id: "loop-1", deadline: deadline)
        Rho::Runner::ExecutionContext.with(context) { yield(env, real, context) }
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

    # The captured lines of one session's process, parsed.
    def capture_lines(path)
      File.readlines(path, encoding: Encoding::UTF_8).map { |line| JSON.parse(line) }
    end
  end
end
