require "test_helper"
require "rho/gateway/delivery_time"

class GatewayDeliveryTimeTest < Minitest::Test
  def test_absolute_time_preserves_the_requested_instant_without_the_machine_zone
    reader = Rho::Gateway::DeliveryTime
    assert_equal "2026-10-03T01:00:00Z", reader.resolve("at 2026-10-03T09:00:00+08:00", now: 0)
    assert_equal "2026-10-03T01:00:00Z", reader.resolve("at 2026-10-03T01:00:00Z", now: 0)
    assert_equal "2026-10-03T01:00:00Z", reader.resolve("at 2026-10-02T21:00:00-0400", now: 0)
  end

  def test_relative_time_and_now_share_the_callers_clock
    now = Time.iso8601("2026-10-02T23:50:00Z").to_f
    assert_equal "2026-10-03T00:10:00Z", resolve("in 20m", now)
    assert_equal "2026-10-02T23:51:30Z", resolve("in 90s", now)
    assert_equal "2026-10-03T01:50:00Z", resolve("in 2h", now)
    assert_equal "2026-10-03T23:50:00Z", resolve("in 1d", now)
    assert_equal "2026-10-02T23:50:00Z", resolve("now", now)
    assert_equal resolve("now", now), resolve("in 0s", now)
  end

  def test_unzoned_incomplete_or_unsupported_time_is_not_guessed
    ["", "tomorrow", "at 2026-10-03T09:00:00", "at 2026-10-03", "at 2026-10-03T25:00:00Z",
      "in", "in 2weeks", "in -1h", "in 1.5h", "in 1234567890s", "now later", "at #{"0" * 100}"].each do |expression|
      error = assert_raises(Rho::Error) { resolve(expression, 0) }
      assert_includes error.message, "offset"
    end
  end

  private

    def resolve(expression, now) = Rho::Gateway::DeliveryTime.resolve(expression, now: now)
end
