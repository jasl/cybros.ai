$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "minitest/autorun"
require "tmpdir"
require "support/screen/definition"
require "support/screen/stamp"

# THE STAMP IS WRITTEN ONCE, BEFORE ANY PAID DRAW: one key=value line per fact, keys unique, values
# one line; a second stamp over a home is refused; a failure between the stamp and the first job
# voids it, keeping it as evidence. The job table rides it and reads back as the jobs the
# definition made. Pure Ruby over a tmpdir.
class ScreenStampHarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)

  def test_the_stamp_reads_back_what_was_written_in_order
    Dir.mktmpdir("screen-stamp") do |home|
      S::Stamp.write(home, [["mode", "fake"], ["launched_at", "2026-09-28T10:00:00Z"], ["note", "a=b"]])
      assert_equal({ "mode" => "fake", "launched_at" => "2026-09-28T10:00:00Z", "note" => "a=b" }, S::Stamp.read(home))
      assert_equal "mode=fake\n", File.readlines(S::Stamp.path(home)).first
      assert_equal Time.utc(2026, 9, 28, 10), S::Stamp.launched_at(S::Stamp.read(home))
      assert_match(/\A[0-9a-f]{64}\z/, S::Stamp.sha256(home))
    end
  end

  def test_a_home_is_stamped_once
    Dir.mktmpdir("screen-stamp") do |home|
      S::Stamp.write(home, [%w[mode fake]])
      error = assert_raises(S::Refused) { S::Stamp.write(home, [%w[mode real]]) }
      assert_includes error.message, "stamped once"
      assert_equal({ "mode" => "fake" }, S::Stamp.read(home), "the first stamp is untouched")
    end
  end

  def test_a_repeated_key_and_a_multiline_value_are_refused_and_nothing_is_written
    Dir.mktmpdir("screen-stamp") do |home|
      assert_raises(S::Refused) { S::Stamp.write(home, [%w[mode fake], %w[mode real]]) }
      assert_raises(S::Refused) { S::Stamp.write(home, [["smoke", "one\ntwo"]]) }
      assert_raises(S::Refused) { S::Stamp.write(home, [["a key", "x"]]) }
      refute File.exist?(S::Stamp.path(home))
    end
  end

  def test_a_voided_stamp_is_kept_aside_and_frees_the_slot
    Dir.mktmpdir("screen-stamp") do |home|
      S::Stamp.write(home, [%w[mode real]])
      voided = S::Stamp.void(home, at: Time.utc(2026, 9, 28, 10, 5, 7))
      assert_equal File.join(home, "stamp.void-20260928T100507Z.txt"), voided
      assert_equal "mode=real\n", File.read(voided)
      refute File.exist?(S::Stamp.path(home))
    end
  end

  def test_the_job_table_reads_back_as_the_definitions_jobs
    jobs = S::Definition.load(FAKE).jobs
    Dir.mktmpdir("screen-stamp") do |home|
      S::Stamp.write(home, [%w[mode fake], *jobs.map { |job| ["job.#{job.index}", job.stamp_line] }])
      assert_equal jobs, S::Stamp.jobs(S::Stamp.read(home))
    end
  end
end
