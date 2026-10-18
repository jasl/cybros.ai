require "test_helper"

class ErrorReportingTest < ActiveSupport::TestCase
  setup do
    @io = StringIO.new
    @logger = ActiveSupport::Logger.new(@io)
    @logger.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }
    Rails.logger.broadcast_to(@logger)
  end

  teardown do
    Rails.logger.stop_broadcasting_to(@logger)
  end

  test "a handled report becomes one event line carrying its context and the error" do
    error = begin
      raise ArgumentError, "the row would not settle"
    rescue ArgumentError => raised
      raised
    end

    Rails.error.report(error, handled: true, severity: :error,
      context: { event: "probe_settle_failed", attempt_id: 42 })

    line = @io.string.lines.grep(/probe_settle_failed/).sole
    assert_match(/\AERROR event=probe_settle_failed attempt_id=42 error_class=ArgumentError /, line)
    assert_includes line, "error_message=the row would not settle backtrace="
    assert_includes line, __FILE__
    assert_no_match(/rails=|job=/, line)
  end

  test "the default handled severity is a warning" do
    Rails.error.report(RuntimeError.new("cable down"), handled: true, context: { event: "probe_publish_failed" })

    assert_match(/\AWARN event=probe_publish_failed error_class=RuntimeError error_message=cable down/,
      @io.string.lines.grep(/probe_publish_failed/).sole)
  end

  test "a report without an event names its source" do
    Rails.error.report(RuntimeError.new("bare"), handled: true, source: "probe")

    assert_match(/event=probe error_class=RuntimeError/, @io.string)
  end
end
