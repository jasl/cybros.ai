require "test_helper"
require "rbconfig"
require "timeout"

class SubprocessTest < Minitest::Test
  def test_exited_command_keeps_stderr_before_its_reader_runs
    with_paused_reader do |reader_started|
      child = Rho::Runner::Subprocess.start(
        RbConfig.ruby, "-e", 'STDERR.write("regex parse error\n"); exit(2)'
      )
      child.stdin.close
      reader_started.pop
      assert_equal 2, child.wait.exitstatus
      assert_equal "regex parse error\n", child.stderr_text
    ensure
      child&.cleanup
    end
  end

  def test_queued_stderr_at_the_capture_limit_is_complete_without_eof
    assert_queued_capture("abcd", truncated: false)
  end

  def test_queued_stderr_beyond_the_capture_limit_reports_truncation_without_eof
    assert_queued_capture("abcde", truncated: true)
  end

  private

  def assert_queued_capture(text, truncated:)
    reader, writer = IO.pipe
    writer.write(text)
    with_paused_reader do |reader_started|
      capture = Rho::Runner::Subprocess.const_get(:BoundedCapture).new(reader, max_bytes: 4)
      reader_started.pop
      result = capture.finish

      assert_equal "abcd", result.content
      assert_equal truncated, result.truncated
    ensure
      capture&.finish
    end
  ensure
    [reader, writer].compact.each { |io| io.close unless io.closed? }
  end

  def with_paused_reader
    reader_started = Queue.new
    release_reader = Queue.new
    reader_thread = nil
    capture_class = Rho::Runner::Subprocess.const_get(:BoundedCapture)

    # The command can exit before the OS schedules its stderr reader. Hold
    # that reader until collection joins it, after the command has exited.
    trace = TracePoint.new(:call, :c_call) do |event|
      if event.method_id == :run && event.defined_class == capture_class
        reader_thread = Thread.current
        reader_started << true
        release_reader.pop
      elsif event.method_id == :join && event.self.equal?(reader_thread)
        release_reader << true
      end
    end

    Timeout.timeout(3) do
      trace.enable(target_thread: nil) do
        yield reader_started
      ensure
        release_reader << true
      end
    end
  ensure
    trace&.disable
  end
end
