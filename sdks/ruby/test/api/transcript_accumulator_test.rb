require "test_helper"

# THE FIVE LAWS OF THE TRANSCRIPT FEED, ASKED ONE AT A TIME.
#
# Every consumer of that feed has to join deltas, throw the streamed half
# away when a retry says so, and reconcile what it printed against the
# sealed body when the turn settles. Three clients were about to write
# that three times; the one that already existed (rho's follower) got the
# third question wrong in a way no test could see, because it held a
# bounded buffer and compared it to an unbounded body.
class TranscriptAccumulatorTest < Minitest::Test
  def accumulator(bound: nil)
    bound.nil? ?
      CybrosAgent::Api::TranscriptAccumulator.new :
      CybrosAgent::Api::TranscriptAccumulator.new(bound: bound)
  end

  def test_deltas_join_in_arrival_order
    subject = accumulator

    assert_equal "half ", subject.accumulate("half ")
    assert_equal "an answer", subject.accumulate("an answer")
    assert_equal "half an answer", subject.text
    assert_equal 14, subject.length
    refute_predicate subject, :empty?
  end

  # A retry throws its attempt's output away, so the next attempt's first
  # delta starts a new answer rather than concatenating onto a discarded one.
  def test_a_reset_discards_the_streamed_half
    subject = accumulator
    subject.accumulate("half an ans")

    assert_nil subject.reset
    assert_predicate subject, :empty?
    assert_equal 0, subject.length

    subject.accumulate("the answer")
    assert_equal "the answer", subject.text
  end

  # THE KEY IS THE RESET SIGNAL. The kernel stamps every item with the
  # round's task key (or the reply's variant), and a delta belonging to a
  # different one is a different answer — not a continuation of this one.
  def test_a_key_switch_resets_and_adopts_the_new_key
    subject = accumulator
    subject.accumulate("a", key: "r1")
    subject.accumulate("b", key: "r2")

    assert_equal "b", subject.text
    assert_equal 1, subject.length
    assert_equal "r2", subject.key
  end

  def test_the_same_key_keeps_accumulating
    subject = accumulator
    subject.accumulate("a", key: "r1")
    subject.accumulate("b", key: "r1")

    assert_equal "ab", subject.text
  end

  # The bound is a memory ceiling on what is HELD; what was accumulated is
  # counted whole, which is what makes the settle comparison exact past it.
  def test_the_bound_drops_the_head_and_the_count_keeps_counting
    subject = accumulator(bound: 8)
    subject.accumulate("abcdefgh")
    subject.accumulate("ijkl")

    assert_equal "efghijkl", subject.text
    assert_equal 12, subject.length
  end

  def test_a_settle_after_deltas_answers_only_the_unprinted_remainder
    subject = accumulator
    subject.accumulate("the ans")

    assert_equal "wer", subject.replace_on_settle("the answer")
    refute_predicate subject, :replaced?
    assert_equal "the answer", subject.text
    assert_equal 10, subject.length
  end

  def test_a_settle_that_the_deltas_already_carried_whole_answers_nothing
    subject = accumulator
    subject.accumulate("the answer")

    assert_equal "", subject.replace_on_settle("the answer")
    refute_predicate subject, :replaced?
  end

  def test_a_settle_that_does_not_continue_the_buffer_is_a_replacement
    subject = accumulator
    subject.accumulate("a wrong start")

    assert_equal "something else", subject.replace_on_settle("something else")
    assert_predicate subject, :replaced?
    assert_equal "something else", subject.text
  end

  # The shape a retry leaves behind: the first attempt was discarded, the
  # second streamed further than its own sealed body reaches (a truncated
  # or edited seal), and prefix arithmetic cannot rescue that. The honest
  # answer is a replacement, and the marker line above it is what tells a
  # person which half is real.
  def test_a_settle_shorter_than_what_this_attempt_streamed_is_a_replacement
    subject = accumulator
    subject.accumulate("a long first attempt")
    subject.reset
    subject.accumulate("a second attempt, streamed further than it sealed")

    assert_equal "short", subject.replace_on_settle("short")
    assert_predicate subject, :replaced?
  end

  # AFTER A RESET, NOTHING IS OUTSTANDING: the marker line already told the
  # person the streamed half was discarded, so a settle with no deltas
  # behind it hands over the whole body as the remainder and claims no
  # second replacement.
  def test_a_settle_with_nothing_streamed_since_the_reset_is_the_whole_body
    subject = accumulator
    subject.accumulate("half an attempt")
    subject.reset

    assert_equal "the whole answer", subject.replace_on_settle("the whole answer")
    refute_predicate subject, :replaced?
  end

  # THE CASE A NAIVE PREFIX CHECK GETS WRONG. Past the bound the buffer is
  # a TAIL, so `settled.start_with?(buffer)` is false for every long reply
  # and a terminal reprints the whole thing under a reset marker.
  def test_a_reply_longer_than_the_bound_still_settles_as_a_continuation
    subject = accumulator(bound: 16)
    body = "z" * 100
    subject.accumulate(body[0, 90])

    assert_equal body[90..], subject.replace_on_settle(body)
    refute_predicate subject, :replaced?
    assert_equal 16, subject.text.bytesize
    assert_equal 100, subject.length
  end

  def test_nothing_moves_for_a_nil_or_empty_delta
    subject = accumulator
    subject.accumulate("said")

    assert_nil subject.accumulate(nil)
    assert_nil subject.accumulate("")
    assert_equal "said", subject.text
    assert_equal 4, subject.length
  end

  # A turn with no content at all: nothing was streamed, nothing settles.
  def test_a_settle_of_nothing_answers_an_empty_string_and_moves_nothing
    subject = accumulator
    subject.accumulate("said")

    assert_equal "", subject.replace_on_settle(nil)
    assert_equal "said", subject.text
    assert_equal 4, subject.length
  end

  def test_the_buffer_is_never_handed_out_mutable
    subject = accumulator
    subject.accumulate("mine")
    handed = subject.text

    assert_predicate handed, :frozen?
    assert_raises(FrozenError) { handed << "yours" }
    assert_equal "mine", subject.text
  end

  # UTF-8 IS NOT THIS MACHINE'S DEFAULT: a delta arrives as bytes off a
  # socket and a character may be split across two of them, so the join
  # has to be bytewise and the answer has to read back as UTF-8.
  def test_a_multibyte_character_split_across_two_deltas_reads_back_whole
    subject = accumulator
    character = "é".dup.force_encoding(Encoding::UTF_8)
    subject.accumulate(character.byteslice(0, 1).force_encoding(Encoding::ASCII_8BIT))
    subject.accumulate(character.byteslice(1, 1).force_encoding(Encoding::ASCII_8BIT))

    assert_equal Encoding::UTF_8, subject.text.encoding
    assert_equal "é", subject.text
    assert_predicate subject.text, :valid_encoding?
    # The remainder is what the deltas did NOT carry: the split character
    # counted as its two bytes, so the settle continues rather than replaces.
    assert_equal " and more", subject.replace_on_settle("é and more")
    refute_predicate subject, :replaced?
  end

  def test_a_snapshot_reconciles_deltas_before_and_after_a_bounded_rejoin
    subject = accumulator(bound: 8)
    subject.accumulate("hello")

    assert_equal " world", subject.replace_snapshot("lo world", length: 11)
    refute_predicate subject, :replaced?
    assert_equal 11, subject.length
    assert_equal "lo world", subject.text
    subject.accumulate("!")
    assert_equal "", subject.replace_snapshot("o world!", length: 12)
    refute_predicate subject, :replaced?
    assert_equal " again", subject.replace_on_settle("hello world! again")
    refute_predicate subject, :replaced?
    assert_equal "d! again", subject.text
  end

  def test_a_snapshot_of_equal_or_shorter_length_can_replace_the_previous_answer
    subject = accumulator
    subject.accumulate("wrong")

    assert_equal "right", subject.replace_snapshot("right", length: 5)
    assert_predicate subject, :replaced?
    assert_equal "done", subject.replace_snapshot("done", length: 4)
    assert_predicate subject, :replaced?
    assert_equal 4, subject.length
    assert_equal "", subject.replace_snapshot("done", length: 4)
    refute_predicate subject, :replaced?
  end

  def test_a_bounded_initial_snapshot_keeps_the_total_without_claiming_a_replacement
    subject = accumulator(bound: 4)

    assert_equal "abcd", subject.replace_snapshot("abcd", length: 40)
    refute_predicate subject, :replaced?
    assert_equal 40, subject.length
    assert_equal "ef", subject.replace_snapshot("cdef", length: 42)
    refute_predicate subject, :replaced?
    assert_equal "cdef", subject.text
  end

  def test_a_gap_larger_than_the_snapshot_window_replaces_the_known_tail
    subject = accumulator(bound: 4)
    subject.accumulate("abcd")

    assert_equal "ijkl", subject.replace_snapshot("ijkl", length: 12)
    assert_predicate subject, :replaced?
    assert_equal 12, subject.length
    assert_equal "ijkl", subject.text
  end

  def test_an_empty_seal_discards_previous_content_but_nil_snapshot_moves_nothing
    subject = accumulator
    subject.accumulate("discarded")

    assert_equal "", subject.replace_snapshot(nil)
    assert_equal "discarded", subject.text
    assert_equal "", subject.replace_on_settle("")
    assert_predicate subject, :replaced?
    assert_predicate subject, :empty?
    assert_equal 0, subject.length
  end

  def test_a_multibyte_snapshot_tail_keeps_byte_counts_and_valid_text
    subject = accumulator(bound: 5)
    subject.accumulate("abé")

    assert_equal "界", subject.replace_snapshot("é界", length: 7)
    refute_predicate subject, :replaced?
    assert_equal 7, subject.length
    assert_equal "é界", subject.text
    assert_predicate subject.text, :valid_encoding?
  end
end
