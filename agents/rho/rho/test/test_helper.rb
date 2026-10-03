$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rho"

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "support/nexus_doubles"
require_relative "support/daemon_harness"
require_relative "support/cli_harness"
require_relative "support/local_rows"
require_relative "support/conversation_servers"

# THE HOST A TEST HANDS A LOADER: the daemon-lifetime infrastructure an
# extension may close over, without booting a daemon to get one. Nothing
# writes under this home — no log, no process table; the checkpoint
# store's member is the daemon's shape (a callable) so the
# extension REGISTERS its two hidden names here, and it opens a throwaway
# store under a tmpdir only when a capture actually asks for one.
module RhoTest
  def self.host
    Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-test-host")),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil,
      checkpoints: -> { checkpoint_store }
    )
  end

  def self.checkpoint_store
    @checkpoint_store ||= begin
      root = Dir.mktmpdir("rho-test-world")
      Rho::Runner::Checkpoints::Store.open(dir: File.join(root, "checkpoints"), root: root)
    end
  end
end
