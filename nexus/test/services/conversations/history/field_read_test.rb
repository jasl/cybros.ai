require "test_helper"

class Conversations::History::FieldReadTest < ActiveSupport::TestCase
  setup do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member))
    turn = conversation.turns.create!(position: 0, kind: "message", role: "user", status: "completed",
      speaker: Speakers::Resolve.member(account: conversation.account, user: users(:member)), control_owner_user: users(:member))
    @variant = turn.variants.create!(position: 0, status: "completed", source: "manual")
  end

  test "UTF-8 windows continue inside one large projected text without losing characters" do
    text = "中🙂文" * 7_000
    body = ContentBodies::Replace.call(owner: @variant, role: "content", entries: [{ "text" => text }], seal: true).body
    pieces = read_all(body, "content")
    assert_operator pieces.length, :>, 2
    assert_equal text, pieces.join
  end

  test "steer continuation advances across text parts and entries with a separate entry ceiling" do
    entries = 23.times.map { |index| { "role" => "user", "parts" => [{ "type" => "text", "text" => "entry#{index}" }] } }
    entries << { "role" => "user", "parts" => [
      { "type" => "text", "text" => "长🙂" * 7_000 }, { "type" => "text", "text" => "last-part" },
    ] }
    body = ContentBodies::Replace.archive(owner: @variant, role: "steers", entries: entries).body
    first = Conversations::History::FieldRead.call(body: body, field: "steers")
    assert_equal (0...20).map { |index| "entry#{index}" }, first.fetch(:text).lines(chomp: true)
    assert_equal 20, Conversations::History::Location.decode(first.dig(:pagination, :next_after)).fetch(:entry_position)
    pieces = read_all(body, "steers")
    expected = entries.flat_map { |entry| entry.fetch("parts").map { |part| part.fetch("text") } }.join
    assert_equal expected, pieces.join.delete("\n")
  end

  test "a continuation can begin an entry whose first text is not its first part" do
    entries = Array.new(20) { { "parts" => [] } } + [{ "parts" => [
      { "type" => "reasoning", "text" => "not searchable" }, { "type" => "text", "text" => "readable" },
    ] }]
    body = ContentBodies::Replace.archive(owner: @variant, role: "steers", entries: entries).body
    assert_equal ["", "readable"], read_all(body, "steers")
  end

  test "malformed and incompatible locations refuse without returning another window" do
    body = ContentBodies::Replace.call(owner: @variant, role: "content", entries: [{ "text" => "small" }], seal: true).body
    ["broken", Conversations::History::Location.encode(entry_position: 0),
      Conversations::History::Location.encode(character_offset: 99)].each do |location|
      assert_raises(Conversations::History::Parameters::Invalid) do
        Conversations::History::FieldRead.call(body: body, field: "content", location: location)
      end
    end
    assert_raises(Conversations::History::Parameters::Invalid) do
      Conversations::History::FieldRead.call(body: body, field: "content", location: "one", after: "two")
    end
  end

  private

    def read_all(body, field)
      pieces, seen = [], []
      after = nil
      loop do
        page = Conversations::History::FieldRead.call(body: body, field: field, after: after)
        text = page.fetch(:text)
        assert text.valid_encoding?
        assert_operator text.bytesize, :<=, Conversations::History::FieldRead::TEXT_BYTES
        pieces << text
        after = page.dig(:pagination, :next_after)
        break unless after

        assert_not_includes seen, after
        seen << after
        assert_operator pieces.length, :<, 20
      end
      pieces
    end
end
