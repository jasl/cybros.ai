require "test_helper"
require "open3"
require "tmpdir"
require "support/world_slots"

# THE SLOT COUNT IS THE MACHINE'S CEILING: two worlds under a stock
# Postgres, three once `max_connections` reaches the raised ceiling, and
# the stock count when the ceiling cannot be read at all.
class WorldSlotsTest < Minitest::Test
  SLOTS = E2E::WorldSlots

  def test_listing_tasks_does_not_probe_the_local_database
    script = <<~RUBY
      require "rake"
      require "support/world_slots"
      E2E::WorldSlots.define_singleton_method(:max_connections) { abort "unexpected database probe" }
      Rake.application.run(["--tasks"])
    RUBY
    output, status = Open3.capture2e({ "E2E_WORLDS" => nil }, Gem.ruby, "-I.", "-e", script,
      chdir: File.expand_path("..", __dir__))

    assert status.success?, output
    assert_includes output, "rake harness_test"
    assert_includes output, "rake e2e"
  end

  def test_two_worlds_under_the_stock_ceiling_and_three_at_the_raised_one
    assert_equal 2, SLOTS.default(100)
    assert_equal 2, SLOTS.default(SLOTS::RAISED_CEILING - 1)
    assert_equal 3, SLOTS.default(SLOTS::RAISED_CEILING)
    assert_equal 3, SLOTS.default(1000)
  end

  def test_an_unreadable_ceiling_is_the_stock_one
    assert_equal 2, SLOTS.default(nil)
    assert_nil SLOTS.max_connections(psql: "/nonexistent/psql", url_base: nil)
  end

  def test_the_ceiling_is_read_as_one_integer_off_the_command
    Dir.mktmpdir do |dir|
      fake = File.join(dir, "psql")
      File.write(fake, "#!/bin/sh\necho ' 250 '\n")
      File.chmod(0o755, fake)

      assert_equal 250, SLOTS.max_connections(psql: fake, url_base: "postgres://x@localhost:5432")
    end
  end
end
