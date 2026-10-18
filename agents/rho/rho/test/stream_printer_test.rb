require "test_helper"

# THE TERMINAL'S HALF OF THE STREAM.
#
# Model text is not lines: it arrives mid-word and mid-sentence, while
# every other thing rho prints IS a line, and the paid lanes parse those
# lines anchored (`^run:`, `^status:`, `^  check 1/3:`). One rule keeps
# both true — a structured line emits the pending newline first — and it
# lives here rather than in twenty call sites.
class StreamPrinterTest < Minitest::Test
  GUTTER = Rho::StreamPrinter::INDENT

  def setup
    @io = StringIO.new
    @printer = Rho::StreamPrinter.new(@io)
  end

  def out = @io.string

  def test_text_arrives_in_its_own_indented_block
    @printer.text("half a ")
    @printer.text("thought")

    assert_equal "#{GUTTER}half a thought", out
  end

  def test_a_newline_inside_a_delta_indents_the_next_line_too
    @printer.text("one\ntwo")

    assert_equal "#{GUTTER}one\n#{GUTTER}two", out
  end

  # THE WHOLE OF THE `^status:` GUARANTEE. A lane that anchors its match
  # goes red the first time a delta leaves the cursor mid-line.
  def test_a_status_line_after_a_delta_starts_on_its_own_line
    @printer.text("half a thought")
    @printer.puts("status:    completed")

    assert_match(/^status:    completed$/, out)
    assert_equal "#{GUTTER}half a thought\nstatus:    completed\n", out
  end

  def test_a_line_printed_with_no_text_above_it_is_byte_identical
    @printer.puts("status:    completed")

    assert_equal "status:    completed\n", out
  end

  def test_a_delta_ending_in_a_newline_leaves_no_blank_line_before_a_status
    @printer.text("a whole line\n")
    @printer.puts("status:    completed")

    assert_equal "#{GUTTER}a whole line\nstatus:    completed\n", out
  end

  # ONE MARKER LINE, and only when there is something to disown.
  def test_a_reset_says_so_once
    @printer.text("half an ans")
    @printer.reset
    @printer.reset

    assert_equal "#{GUTTER}half an ans\n#{Rho::StreamPrinter::RESET_LINE}\n", out
  end

  def test_a_reset_before_anything_was_printed_says_nothing
    @printer.reset

    assert_equal "", out
  end

  def test_reasoning_rides_a_second_block_and_does_not_interleave_a_line
    @printer.text("the ans")
    @printer.reasoning("thinking")
    @printer.text("wer")

    assert_equal "#{GUTTER}the ans\n#{GUTTER}thinking\n#{GUTTER}wer", out
  end

  # e2e reads this output through a pipe; an escape code in it is a byte
  # every anchored lane would have to know about.
  def test_no_escape_codes_reach_a_non_tty
    @printer.reasoning("thinking")

    refute_includes out, "\e"
  end

  def test_a_multibyte_character_split_across_two_deltas_reads_back_whole
    character = "é".dup.force_encoding(Encoding::UTF_8)
    @printer.text(character.byteslice(0, 1).force_encoding(Encoding::ASCII_8BIT))
    @printer.text(character.byteslice(1, 1).force_encoding(Encoding::ASCII_8BIT))

    assert_equal "#{GUTTER}é", out.dup.force_encoding(Encoding::UTF_8)
  end

  # THE POLLING ENTRY POINT (`rho watch` reads a snapshot; nobody hands it
  # deltas): each poll prints only what grew.
  def test_a_poll_prints_only_the_growth
    @printer.partial("the ")
    @printer.partial("the ans")
    @printer.partial("the answer")

    assert_equal "#{GUTTER}the answer", out
  end

  def test_a_poll_that_moved_nothing_prints_nothing
    @printer.partial("the answer")
    before = out.dup
    @printer.partial("the answer")

    assert_equal before, out
  end

  def test_a_row_that_does_not_continue_what_was_shown_restarts
    @printer.partial("a wrong start")
    @printer.partial("something else")

    assert_equal "#{GUTTER}a wrong start\n#{Rho::StreamPrinter::RESET_LINE}\n#{GUTTER}something else", out
  end

  def test_a_nil_row_prints_nothing
    @printer.partial(nil)
    @printer.partial("")

    assert_equal "", out
  end

  # PAST THE DAEMON'S OWN BOUND the row is a TAIL: `text_length` says how
  # much went in, and without it every poll reads as a replacement and
  # reprints the whole window.
  def test_a_bounded_row_prints_only_the_growth_the_length_names
    body = (0...200).map { |index| format("%03d.", index) }.join
    @printer.partial(body[0, 100], length: 400)
    @printer.partial(body[100, 100], length: 500)

    assert_equal "#{GUTTER}#{body[0, 100]}#{body[100, 100]}", out
  end

  # HOW `rho follow` JOINS: the snapshot frame seeds the block with what
  # was accumulated before the reader arrived, and the deltas continue it.
  def test_a_snapshot_seeds_the_block_and_deltas_continue_it
    @printer.partial("the ")
    @printer.text("answer")

    assert_equal "#{GUTTER}the answer", out
  end

  def test_a_rejoin_after_live_deltas_prints_only_the_unseen_bytes
    @printer.partial("the ")
    @printer.text("ans")
    @printer.partial("the answer")

    assert_equal "#{GUTTER}the answer", out
  end

  def test_a_replacement_snapshot_after_live_deltas_prints_a_marker_once
    @printer.text("wrong")
    @printer.partial("right")
    @printer.partial("right")

    assert_equal "#{GUTTER}wrong\n#{Rho::StreamPrinter::RESET_LINE}\n#{GUTTER}right", out
  end

  def test_an_empty_rejoin_snapshot_discards_the_previous_stream_before_new_deltas
    @printer.text("wrong")
    @printer.partial("", length: 0)
    @printer.text("right")
    @printer.partial("right")

    assert_equal "#{GUTTER}wrong\n#{Rho::StreamPrinter::RESET_LINE}\n#{GUTTER}right", out
  end

  def test_flush_and_print_reach_the_underlying_io
    @printer.print("raw")
    @printer.flush
    @printer.puts("status:    completed")

    assert_equal "raw\nstatus:    completed\n", out
  end
end
