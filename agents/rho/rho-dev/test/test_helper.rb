$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rho/dev"
# rho's whole test support tree — `RhoTest::CliHarness`, `NexusDoubles`,
# `DaemonHarness`, `LocalRows`, minitest — by relative path: one
# implementation of the scripted daemons, shared with the gem the verbs
# format. rho's helper resolves its own `lib` by its own `__dir__`.
require_relative "../../rho/test/test_helper"

module RhoDevTest
  # The gem's `lib`, the one directory a rho process needs on its load
  # path to answer `require "rho/dev"` — what the e2e harness hands every
  # child through `RUBYLIB`, and what a developer's shell exports.
  LIB = File.expand_path("../lib", __dir__)
  RHO_ROOT = File.expand_path("../../rho", __dir__)
  EXE = File.join(RHO_ROOT, "exe", "rho")
  # The extension's installed bundle also contains rho. Keep the Gemfile
  # and lock paired: switching only the Gemfile can overwrite this lock,
  # while switching both to rho's bundle requires gems this suite does
  # not install. Frozen mode makes any dependency drift fail loudly.
  CHILD_BUNDLE_ENV = {
    "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__),
    "BUNDLE_LOCKFILE" => File.expand_path("../Gemfile.lock", __dir__),
    "BUNDLE_FROZEN" => "true",
  }.freeze
  # The forty: the old Ops set, the four that left the core, `turns` (the replay's spine from a terminal), and the
  # conversation's environment pair (`environment`, the record read and bound; `environments`, the live table).
  VERBS = %w[
    loops providers watch result pause resume answer follow transcript task relay fetch graph request prompt
    append phases attach retry abandon compact approve deny rules delete btw side inputs skills rewind
    regenerate variant activate conversation do say stop adaptations turns environment environments port
  ].freeze
end
