require "test_helper"

class Schedule::RuleTest < ActiveSupport::TestCase
  test "once normalizes an offset and keeps the database microsecond precision" do
    rule = Schedule::Rule.parse(kind: "once", run_at: "2026-10-02T09:00:00.123456789+08:00")

    assert_predicate rule, :valid?
    assert_equal({ "kind" => "once", "run_at" => "2026-10-02T01:00:00.123456Z" }, rule.to_h)
    assert_equal Time.iso8601("2026-10-02T01:00:00.123456Z"), rule.run_at
    assert_equal rule.to_h, Schedule::Rule.parse(rule.to_h).to_h
  end

  test "once includes its exact first boundary but has no later occurrence" do
    rule = Schedule::Rule.parse(kind: "once", run_at: "2026-10-02T01:00:00Z")
    at = Time.utc(2026, 10, 2, 1)

    assert_equal at, rule.next_after(at - 1)
    assert_equal at, rule.first_at_or_after(at)
    assert_nil rule.next_after(at)
    assert_nil rule.first_at_or_after(at + 1)
  end

  test "absolute dates require an offset and a real calendar date" do
    [nil, "", "2026-10-02T09:00:00", "2026-02-30T09:00:00Z", "2026-10-02T25:00:00Z", "x" * 41].each do |value|
      rule = Schedule::Rule.parse(kind: "once", run_at: value)

      assert_not rule.valid?, value.inspect
      assert rule.errors.added?(:run_at, :blank), value.inspect
      assert_nil rule.to_h.fetch("run_at")
    end
  end

  test "absolute dates refuse invalid offsets and unsupported leap seconds" do
    ["2026-10-02T09:00:00+99:99", "2026-10-02T09:00:00+24:00", "2026-10-02T09:00:00+08:99", "2026-10-02T09:00:60Z"].each do |value|
      rule = Schedule::Rule.parse(kind: "once", run_at: value)

      assert_not rule.valid?, value
      assert rule.errors.added?(:run_at, :blank), value
      assert_nil rule.to_h.fetch("run_at")
    end
  end

  test "interval keeps its anchor when time passes several occurrences" do
    rule = Schedule::Rule.parse(kind: "interval", every_seconds: "60", starts_at: "2026-10-02T18:00:00+08:00")
    start = Time.utc(2026, 10, 2, 10)

    assert_predicate rule, :valid?
    assert_equal 60, rule.to_h.fetch("every_seconds")
    assert_equal "2026-10-02T10:00:00.000000Z", rule.to_h.fetch("starts_at")
    assert_equal start, rule.next_after(start - 1)
    assert_equal start, rule.first_at_or_after(start)
    assert_equal start + 60, rule.next_after(start)
    assert_equal start + 1020, rule.next_after(start + 1001)
    assert_equal start + 1020, rule.first_at_or_after(start + 1020)
    assert_equal start + 1080, rule.next_after(start + 1020)
  end

  test "interval arithmetic preserves fractional boundaries without float rounding" do
    rule = Schedule::Rule.parse(kind: "interval", every_seconds: 60, starts_at: "2026-10-02T10:00:00.123456Z")
    boundary = Time.iso8601("2026-10-02T10:01:00.123456Z")

    assert_equal boundary, rule.next_after(boundary - Rational(1, 1_000_000))
    assert_equal boundary, rule.first_at_or_after(boundary)
    assert_equal boundary + 60, rule.next_after(boundary)
  end

  test "interval rejects malformed durations and keeps both allowed bounds" do
    [nil, 0, 59, 31_536_001, 60.5, "60.0", "60s", "1e3", "9" * 9].each do |value|
      rule = Schedule::Rule.parse(kind: "interval", every_seconds: value, starts_at: "2026-10-02T10:00:00Z")

      assert_not rule.valid?, value.inspect
      assert rule.errors.of_kind?(:every_seconds, :inclusion), value.inspect
      assert_nothing_raised { JSON.generate(rule.to_h) }
    end

    [60, 31_536_000].each do |value|
      rule = Schedule::Rule.parse(kind: "interval", every_seconds: value, starts_at: "2026-10-02T10:00:00Z")
      assert_predicate rule, :valid?
    end
  end

  test "interval requires an absolute starting point" do
    rule = Schedule::Rule.parse(kind: "interval", every_seconds: 60, starts_at: "2026-10-02T10:00:00")

    assert_not rule.valid?
    assert rule.errors.added?(:starts_at, :blank)
    assert_nil rule.to_h.fetch("starts_at")
  end

  test "daily uses the named zone independently of the cursor offset" do
    rule = Schedule::Rule.parse(kind: "daily", local_time: "09:15", time_zone: "Asia/Shanghai")

    assert_predicate rule, :valid?
    assert_equal Time.utc(2026, 10, 2, 1, 15), rule.next_after(Time.iso8601("2026-10-01T17:14:59-08:00"))
    assert_equal Time.utc(2026, 10, 2, 1, 15), rule.first_at_or_after(Time.utc(2026, 10, 2, 1, 15))
    assert_equal Time.utc(2026, 10, 3, 1, 15), rule.next_after(Time.utc(2026, 10, 2, 1, 15))
    assert_equal rule.to_h, Schedule::Rule.parse(rule.to_h).to_h
  end

  test "daily skips a clock time missing at the spring DST transition" do
    rule = Schedule::Rule.parse(kind: "daily", local_time: "02:30", time_zone: "America/New_York")

    assert_predicate rule, :valid?
    assert_equal Time.utc(2026, 3, 9, 6, 30), rule.next_after(Time.utc(2026, 3, 7, 12))
  end

  test "daily uses only the earliest instant of a repeated clock time" do
    rule = Schedule::Rule.parse(kind: "daily", local_time: "01:30", time_zone: "America/New_York")
    first = Time.utc(2026, 11, 1, 5, 30)
    second = Time.utc(2026, 11, 1, 6, 30)
    tomorrow = Time.utc(2026, 11, 2, 6, 30)

    assert_predicate rule, :valid?
    assert_equal first, rule.next_after(Time.utc(2026, 11, 1, 4))
    assert_equal first, rule.first_at_or_after(first)
    assert_equal tomorrow, rule.next_after(first)
    assert_equal tomorrow, rule.next_after(second - 60)
    assert_equal tomorrow, rule.first_at_or_after(second)
  end

  test "daily skips a date removed by a dateline change" do
    rule = Schedule::Rule.parse(kind: "daily", local_time: "09:00", time_zone: "Pacific/Apia")

    assert_predicate rule, :valid?
    assert_equal Time.utc(2011, 12, 30, 19), rule.next_after(Time.utc(2011, 12, 29, 20))
  end

  test "daily rejects invalid local times and non-IANA time zones" do
    [nil, "9:00", "24:00", "12:60", "12:00:00", "x" * 100].each do |value|
      rule = Schedule::Rule.parse(kind: "daily", local_time: value, time_zone: "UTC")
      assert_not rule.valid?, value.inspect
      assert rule.errors.added?(:local_time, :blank), value.inspect
    end

    [nil, "", "+08:00", "Beijing", "Unknown/Zone", "x" * 256].each do |value|
      rule = Schedule::Rule.parse(kind: "daily", local_time: "09:00", time_zone: value)
      assert_not rule.valid?, value.inspect
      assert rule.errors.added?(:time_zone, :invalid), value.inspect
      assert_nothing_raised { JSON.generate(rule.to_h) }
    end
  end

  test "unknown kinds remain invalid and serializable" do
    [nil, {}, { kind: "weekly" }].each do |value|
      rule = Schedule::Rule.parse(value)

      assert_not rule.valid?
      assert rule.errors.of_kind?(:kind, :inclusion)
      assert_nothing_raised { JSON.generate(rule.to_h) }
    end
  end

  test "unconsumed fields do not change the chosen rule" do
    rule = Schedule::Rule.parse(kind: "once", run_at: "2026-10-02T01:00:00Z", every_seconds: "bad", unknown: true)

    assert_predicate rule, :valid?
    assert_equal({ "kind" => "once", "run_at" => "2026-10-02T01:00:00.000000Z" }, rule.to_h)
  end
end
