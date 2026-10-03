require "test_helper"
require "open3"

# THE OPT-IN, KEPT HONEST BY A SUBPROCESS.
#
# The realtime plane is meant to cost nothing until a consumer asks for it:
# `async-websocket` is consumer-supplied, the client that needs it is
# require-guarded, and a program that follows a run over HTTP alone should
# not load a byte of it. That property is invisible from inside this suite,
# where the dev Gemfile has the socket stack installed and any accidental
# require would simply succeed.
#
# So it is checked from a clean interpreter, which is the only place the
# question can actually be asked.
class ApiOptionalRealtimeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def ruby(source)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.join(ROOT, "lib")}", "-e", source
    )
    [stdout.strip, stderr.strip, status]
  end

  def test_the_base_gem_loads_no_websocket_stack
    stdout, stderr, status = ruby(<<~RUBY)
      require "cybros_agent"
      loaded = $LOADED_FEATURES.grep(%r{async|websocket|protocol-http})
      puts(loaded.empty? ? "clean" : "LOADED: \#{loaded.first(3).join(", ")}")
    RUBY

    assert status.success?, stderr
    assert_equal "clean", stdout,
      "requiring the gem must not pull the realtime dependency in behind the caller's back"
  end

  # The point of the split: a consumer can RECOGNIZE a lost connection — and
  # decide what to do about it — without installing the thing that raises it.
  def test_the_realtime_errors_are_nameable_without_the_dependency
    stdout, stderr, status = ruby(<<~RUBY)
      require "cybros_agent"
      names = [
        CybrosAgent::Realtime::ConnectionLostError,
        CybrosAgent::Realtime::SubscriptionRejectedError,
        CybrosAgent::Realtime::SubscriptionBackpressureError,
        CybrosAgent::Realtime::TimeoutError,
      ]
      puts names.all? { |name| name < CybrosAgent::Error } ? "nameable" : "wrong ancestry"
    RUBY

    assert status.success?, stderr
    assert_equal "nameable", stdout
  end

  # A REST follower is a complete follower. This drives the pump end to end
  # against a stub in a clean interpreter — no HTTP, no socket, no gems.
  def test_a_replay_only_feed_runs_with_nothing_installed
    stdout, stderr, status = ruby(<<~RUBY)
      require "cybros_agent"
      Page = Data.define(:items, :next_after, :watermark)
      Event = Data.define(:sequence, :cursor, :public_id)
      pages = [
        Page.new(items: [Event.new(sequence: 1, cursor: "c1", public_id: "e1")], next_after: "c1", watermark: 2),
        Page.new(items: [Event.new(sequence: 2, cursor: "c2", public_id: "e2")], next_after: "c2", watermark: 2),
      ]
      feed = CybrosAgent::KernelFeed.new(replay: ->(_cursor) { pages.shift })
      seen = []
      feed.each { |event| seen << event.sequence }
      puts "\#{seen.join(",")} at \#{feed.position.sequence}"
    RUBY

    assert status.success?, stderr
    assert_equal "1,2 at 2", stdout
  end
end
