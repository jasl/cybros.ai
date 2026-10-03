$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/acp"
# rho's whole test support tree — `RhoTest::CliHarness`, `NexusDoubles`,
# `DaemonHarness`, `LocalRows`, minitest — by relative path: one
# implementation of the scripted daemons, shared with the surface that
# will drive them. rho's helper resolves its own `lib` by its own `__dir__`.
require_relative "../../rho/test/test_helper"
require_relative "support/core_double"
require_relative "support/agent_harness"

module RhoAcpTest
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe", "rho-acp")
  # This gem's own bundle for the spawned exe, all three names, the way
  # the e2e harness spawns every child: Bundler's `bundle exec` exports
  # `BUNDLE_LOCKFILE` beside `BUNDLE_GEMFILE`, and a child that inherits
  # one while naming another resolves the wrong bundle and writes it over
  # the wrong lockfile. Frozen: a drift fails loudly.
  CHILD_BUNDLE_ENV = {
    "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
    "BUNDLE_LOCKFILE" => File.join(ROOT, "Gemfile.lock"),
    "BUNDLE_FROZEN" => "true",
  }.freeze
end
