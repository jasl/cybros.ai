require "test_helper"

# THE ONE PARSER of a caller's "not before" (owner 2026-09-15, item 12):
# both doors — the member controller and the `send` executor — read the
# two wire spellings through this module alone, so the grammar cannot
# drift between them. Pinned here: the shape check that precedes
# `Time.iso8601` (a naive stamp, a six-digit year, an over-long string),
# the duration grammar against the clock it is given, and the two
# non-readings (both spellings; neither).
class Conversations::Inputs::DeliverAtTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 9, 16, 9, 0, 0)

  def parse(at: nil, in_: nil) = Conversations::Inputs::DeliverAt.parse(at: at, in_: in_)

  test "an absolute time with Z or an offset resolves to that instant; fractional seconds are kept" do
    {
      "2026-09-16T09:00:00Z" => Time.utc(2026, 9, 16, 9, 0, 0),
      "2026-09-16T09:00:00+08:00" => Time.utc(2026, 9, 16, 1, 0, 0),
      "2026-09-16T09:00:00-0500" => Time.utc(2026, 9, 16, 14, 0, 0),
      "2026-09-16t09:00:00z" => Time.utc(2026, 9, 16, 9, 0, 0),
    }.each do |wire, instant|
      reading = parse(at: wire)
      assert_nil reading.refusal, wire
      assert_equal instant, reading.time, wire
    end

    fractional = parse(at: "2026-09-16T09:00:00.5Z")
    assert_nil fractional.refusal
    assert_equal Time.utc(2026, 9, 16, 9, 0, 0), fractional.time.floor
    assert_equal 500_000, fractional.time.usec
  end

  # `Time.iso8601` reads an offset-less stamp in the PROCESS's zone (verified
  # on this host: local `+0800`), and a six-digit year parses but overflows
  # the column — the shape refuses both before the parse ever runs.
  # `Time.iso8601` rolls a 30th of February over to March; a 13th month it
  # refuses, and that refusal is wrapped as the shape's own.
  test "a naive stamp, a six-digit year, an over-long string, a month that does not exist and junk refuse by name" do
    [
      "2026-09-16T09:00:00",
      "999999-09-16T09:00:00Z",
      "2026-09-16T09:00:00Z" * 3,
      "2026-13-01T00:00:00Z",
      "2026-09-16 09:00:00Z",
      "tomorrow",
      "",
    ].each do |wire|
      reading = parse(at: wire)
      assert_equal :deliver_at_invalid, reading.refusal, wire.inspect
      assert_nil reading.time, wire.inspect
    end
  end

  test "a delay resolves against the clock it is given; 0s is now; junk refuses deliver_in_invalid" do
    { "90s" => 90, "20m" => 20 * 60, "2h" => 2 * 3600, "1d" => 86_400, "0s" => 0 }.each do |wire, seconds|
      reading = parse(in_: wire)
      assert_nil reading.refusal, wire
      assert_equal seconds, reading.delay_seconds, wire
      assert_equal NOW + seconds, reading.resolve(now: NOW), wire
    end

    ["20 m", "1w", "-5m", "m", "1.5h", "1000000000s", "20", "in 30m"].each do |wire|
      reading = parse(in_: wire)
      assert_equal :deliver_in_invalid, reading.refusal, wire.inspect
      assert_nil reading.time, wire.inspect
    end
  end

  test "both spellings refuse deliver_at_ambiguous; neither reads as no time and no refusal" do
    both = parse(at: "2026-09-16T09:00:00Z", in_: "20m")
    assert_equal :deliver_at_ambiguous, both.refusal
    assert_nil both.time

    neither = parse
    assert_nil neither.refusal
    assert_nil neither.time
  end
end
