require "test_helper"

# WHAT WAS DROPPED, SAID OUT LOUD. Both compaction planes cut a history
# down to a room smaller than the history; both used to do it silently.
# A summarizer handed a history beginning mid-sentence with no marker
# cannot know a gap is there, so it summarizes over it — and from then
# on the gap is invisible for the rest of the session.
class Nexus::ElisionTest < ActiveSupport::TestCase
  test "a whole-part cut names how many, and the count is honest" do
    parts = ["a" * 60, "b" * 60, "c" * 10]

    fitted = Nexus::Elision.fit(parts, 120)

    assert fitted.start_with?("[... 1 earlier round(s) elided to fit ...]")
    assert_operator fitted.bytesize, :<=, 120,
      "the marker is inside the room here too — clamping the body to the full " \
      "room and THEN prepending the note overran the bound by the note's width"
    refute_includes fitted, "a" * 60, "the oldest part is what goes"
    assert_includes fitted, "b" * 60
    assert_includes fitted, "c" * 10
  end

  test "the noun follows the plane, because a loop has rounds and a conversation does not" do
    parts = ["a" * 60, "b" * 60]
    assert_includes Nexus::Elision.fit(parts, 60, noun: "exchange"), "earlier exchange(s)"
  end

  test "nothing dropped means no marker" do
    assert_equal "one\n\ntwo", Nexus::Elision.fit(%w[one two], 100)
  end

  test "the caller never gets an empty history back" do
    # Every part is past the room. Dropping to nothing is not a smaller
    # history, it is no history — so the last one stays and the byte
    # clamp takes over from there.
    fitted = Nexus::Elision.fit(["a" * 500, "b" * 500], 100)

    assert_equal 100, fitted.bytesize
    assert fitted.end_with?("b"), "what survives is the NEWEST material"
  end

  test "a byte clamp keeps the newest material and says what it dropped" do
    clamped = Nexus::Elision.clamp("#{"old" * 100}NEWEST", 100)

    assert_equal 100, clamped.bytesize, "the marker is inside the room, not added to it"
    assert clamped.start_with?("[... 206 earlier bytes elided to fit ...]")
    assert clamped.end_with?("NEWEST")
  end

  # THE ROOM CAN BE TOO SMALL FOR THE MARKER ITSELF. Prepending it anyway
  # would push the result past the bound it was clamped for — which, on
  # the delegated arm, is a `tool_input` whose validation then raises
  # inside a scheduling pass. Content wins; the note is what yields.
  test "a room too small for the marker yields the marker, not the bound" do
    clamped = Nexus::Elision.clamp("x" * 500, 20)

    assert_equal 20, clamped.bytesize
    assert_equal "x" * 20, clamped
  end

  ["原始文本。", "🚀"].each do |text|
    [19, 100].each do |room|
      test "a #{room} byte tail preserves complete characters in #{text}" do
        original = text * 100
        clamped = Nexus::Elision.clamp(original, room)

        assert_predicate clamped, :valid_encoding?
        assert_operator clamped.bytesize, :<=, room
        retained = clamped.split("\n\n", 2).last
        assert original.end_with?(retained), "the retained text is an unchanged suffix"
        assert_not_includes clamped, "�"
      end
    end
  end

  test "no room at all is empty, not a marker" do
    assert_equal "", Nexus::Elision.clamp("x" * 500, 0)
    assert_equal "", Nexus::Elision.clamp("x" * 500, -5)
  end

  test "text inside the room is returned untouched, identically" do
    text = "small"
    assert_same text, Nexus::Elision.clamp(text, 100)
  end
end
