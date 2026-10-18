$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/browser"
require "fileutils"
require "tmpdir"
require "minitest/autorun"

module BrowserTest
  # THE TOOLS' EXECUTION ENVIRONMENT, over a throwaway root, with a
  # context bound for the block the way the pool binds one on a worker —
  # every tool checks cancellation at its own checkpoints and reads it
  # off the thread.
  module Helpers
    def with_tool_env
      Dir.mktmpdir("rho-browser-test") do |root|
        real = File.realpath(root)
        env = Rho::Runner::ToolEnv.new(root: real, artifacts_dir: File.join(real, ".artifacts"))
        Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new) do
          yield(env, real)
        end
      end
    end
  end
end
