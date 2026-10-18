# The log lines a block wrote, one string per line and the message alone —
# a test reads a kernel `event=` line the way an operator greps for it.
module LogCapture
  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
    Rails.logger.broadcast_to(logger)
    yield
    io.string.lines
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end
end
