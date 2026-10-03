require "test_helper"
require "tmpdir"

class ProcessesOutputTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("rho-output")
    @path = File.join(@dir, "p1.log")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def test_notes_first_last_and_the_line_waited_for
    output = Rho::Processes::Output.new(path: @path, wait_for: "LISTENING on")

    output.append("starting\n\e[32mListening on http://localhost:3000\e[0m\nreq 1\n")
    output.append("req 2 (partial")

    assert_equal "starting", output.first_line
    assert_equal "Listening on http://localhost:3000", output.ready_line
    assert output.matched?
    assert_equal "req 1", output.last_line
    output.eof!
    assert_equal "req 2 (partial", output.last_line
  end

  def test_ready_line_falls_back_to_the_first_line
    output = Rho::Processes::Output.new(path: @path, wait_for: "never")
    output.append("hello\nworld\n")

    refute output.matched?
    assert_equal "hello", output.ready_line
  end

  def test_keeps_a_head_and_a_tail_and_says_what_fell_between
    output = Rho::Processes::Output.new(path: @path)
    line = "#{"x" * 99}\n"
    total = (Rho::Processes::Output::HEAD_BYTES + Rho::Processes::Output::TAIL_BYTES) / 100 + 2000
    total.times { |i| output.append(format("%06d %s", i, line)) }

    text = output.lines(5)
    assert_includes text, format("%06d", total - 1)
    whole = output.lines(10_000_000, max_bytes: 10_000_000)
    assert_includes whole, "000000 "
    assert_includes whole, "earlier output dropped"
    # The dropped size is the runner's one formatter's spelling
    # (`Truncation.format_size`, I-11): `123.4KB`, no space, never rho's own.
    assert_match(/\[… \d+(\.\d)?(B|KB|MB) of earlier output dropped; the log file has it …\]/, whole)
    # And a reader's default bound is the runner's one output bound, read
    # by name: a whole read of this buffer is cut to it.
    bounded = output.lines(10_000_000)
    assert_operator bounded.bytesize, :<=, Rho::Runner::Truncation::DEFAULT_MAX_BYTES
    assert_operator bounded.bytesize, :>, Rho::Runner::Truncation::DEFAULT_MAX_BYTES - 200, "the bound, not a smaller one"
    assert_operator whole.bytesize, :<=, Rho::Processes::Output::HEAD_BYTES + Rho::Processes::Output::TAIL_BYTES + 200
    assert_equal total * 107, File.size(@path), "the file is the complete record"
  end

  def test_lines_are_capped_by_bytes_at_a_line_boundary
    output = Rho::Processes::Output.new(path: @path)
    5.times { |i| output.append("#{i}#{"y" * 999}\n") }

    text = output.lines(5, max_bytes: 2500)
    assert_operator text.bytesize, :<=, 2500
    assert_match(/\A[34]y/, text)
  end

  def test_rotates_the_file_once_at_the_cap
    output = Rho::Processes::Output.new(path: @path, rotate_at: 1000)
    3.times { output.append("z" * 600) }

    assert_path_exists "#{@path}.1"
    assert_equal 1200, File.size("#{@path}.1")
    assert_equal 600, File.size(@path)
  end

  def test_a_disk_that_says_no_does_not_stop_the_reader
    output = Rho::Processes::Output.new(path: File.join(@dir, "missing-dir", "p.log"))
    output.append("still here\n")

    assert_equal "still here", output.lines(1)
    assert_match(/ENOENT/, output.file_error)
  end

  def test_invalid_bytes_and_carriage_returns_are_survivable
    output = Rho::Processes::Output.new(path: @path)
    output.append("\xC2 bad\r\n".b)
    output.append("100%\r")

    assert_equal "? bad", output.first_line
    assert_equal "? bad\n100%", output.lines(10)
  end
end
