require "test_helper"
require "json"

# THE TIMED POSTER of a running tool's tails (executor.md "Progress"): the
# extension's model for the other direction — a handler hands in, the
# reactor posts when the cadence allows, only the newest tail is kept, one
# refusal ends the posting. And the mirrored cadence floor is pinned equal
# to the kernel's published one, as the submit bound's mirror is in spirit.
class ProgressTest < Minitest::Test
  PACK = File.expand_path("../../../../contracts/nexus/v1/size_bounds.json", __dir__)

  def progress(interval_ms: 250, &post)
    @now = 0.0
    @posts = []
    Rho::Runner::Progress.new(clock: -> { @now }, interval_ms: interval_ms,
      post: post || ->(text) { @posts << [@now, text]; true })
  end

  def test_the_mirrored_cadence_floor_equals_the_kernels_published_one
    published = JSON.parse(File.read(PACK, encoding: Encoding::UTF_8)).fetch("progress_min_interval_ms")
    assert_equal published, Rho::Runner::Progress::MIN_INTERVAL_MS,
      "the runner mirrors nexus's floor; update the copy when the kernel moves"
  end

  def test_the_newest_tail_goes_out_once_per_interval_and_the_wait_says_when
    subject = progress
    assert_in_delta 0.25, subject.wait, 1e-9, "nothing pending: look again in one interval"

    subject.tail("a")
    subject.tail("ab")
    assert_equal 0.0, subject.wait
    assert subject.flush
    assert_equal [[0.0, "ab"]], @posts, "the newest tail, the earlier one superseded"
    assert_in_delta 0.25, subject.wait, 1e-9

    subject.tail("abc")
    assert_in_delta 0.25, subject.wait, 1e-9
    refute subject.flush, "not due yet"
    @now = 0.1
    refute subject.flush
    @now = 0.25
    assert subject.flush
    assert_equal [[0.0, "ab"], [0.25, "abc"]], @posts

    subject.tail("abc")
    refute_predicate subject, :pending?, "a tail already posted is nothing new"
    subject.tail("")
    refute_predicate subject, :pending?, "an empty tail is nothing new"
  end

  def test_a_refusal_stops_the_posting
    subject = progress { |_text| false }
    subject.tail("a")
    refute subject.flush
    assert_predicate subject, :stopped?
    subject.tail("b")
    assert_nil subject.wait, "stopped: the wait is the clamp's alone"
    refute subject.flush
  end

  def test_the_interval_must_be_positive
    assert_raises(ArgumentError) { Rho::Runner::Progress.new(post: ->(_) { true }, clock: -> { 0 }, interval_ms: 0) }
  end
end
