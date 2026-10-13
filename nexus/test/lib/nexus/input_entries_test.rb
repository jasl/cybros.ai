require "test_helper"

# Decomposition enables reuse: a structured prompt that arrives as one fragment stores a full copy
# every turn. These tests pin the split itself; the writer test proves the saving it buys.
class Nexus::InputEntriesTest < ActiveSupport::TestCase
  def text_message(text, role: "user")
    Nexus::TextInputMessage.new(
      role: role, parts: [Nexus::TextInputPart.new(type: "text", text: text)]
    )
  end

  test "a message array becomes one entry per message" do
    entries = Nexus::InputEntries.for([text_message("first"), text_message("second", role: "assistant")])

    assert_equal 2, entries.length
    assert_equal(
      { "role" => "user", "parts" => [{ "type" => "text", "text" => "first" }] },
      entries.first
    )
  end

  # The point of the contract: an unchanged message must canonicalize to the
  # same bytes it had last turn, or nothing ever deduplicates.
  test "an unchanged message decomposes to identical bytes across calls" do
    prefix = [text_message("keep me"), text_message("and me", role: "assistant")]

    first = Nexus::InputEntries.for(prefix)
    second = Nexus::InputEntries.for(prefix + [text_message("new turn")])

    assert_equal first, second.first(2)
    assert_equal first.map { |entry| Nexus::CanonicalJson.encode(entry) },
      second.first(2).map { |entry| Nexus::CanonicalJson.encode(entry) }
  end

  test "a string array becomes one entry per string" do
    assert_equal [{ "text" => "a" }, { "text" => "b" }], Nexus::InputEntries.for(%w[a b])
  end

  # Content with no internal structure is legitimately one entry — that is the
  # only case where a single fragment is the right answer.
  test "an unstructured prompt is one entry and absent input is none" do
    assert_equal [{ "text" => "draw a cat" }], Nexus::InputEntries.for("draw a cat")
    assert_empty Nexus::InputEntries.for(nil)
  end

  # A shape nobody taught it must stop here rather than be silently flattened
  # into one opaque fragment.
  test "an unknown element shape raises instead of flattening" do
    assert_raises(ArgumentError) { Nexus::InputEntries.for([{ "role" => "user" }]) }
  end

  # The inverse is why both directions live in one file: the request writer
  # reads back what acceptance wrote, and a disagreement between them would
  # change what gets sent.
  test "every workload's accepted input survives the round trip" do
    {
      "text_generation" => [text_message("hello"), text_message("hi", role: "assistant")],
      "embedding" => %w[first second],
      "image_generation" => "draw a cat",
      "speech_generation" => "say this",
      "transcription" => "a hint",
    }.each do |workload, value|
      entries = Nexus::InputEntries.for(value)

      assert_equal value, Nexus::InputEntries.from(entries: entries, workload: workload),
        "#{workload} did not survive decomposition"
    end
  end

  # A wire's label on the assistant message it produced rides the sealed
  # request with the lane it came from, so a retry resends it. A message
  # without one decomposes to exactly the bytes it always had — the
  # prefix a provider's cache already holds.
  test "an assistant message round-trips its phase and origin, and a plain message's bytes do not change" do
    origin = { "provider_id" => "openai_api", "model_id" => "gpt-6-sol", "api_format" => "openai_responses" }
    phased = Nexus::TextInputMessage.new(role: "assistant", phase: "commentary", native_origin: origin,
      parts: [Nexus::TextInputPart.new(type: "text", text: "Reading the file.")])

    entry = Nexus::InputEntries.for([phased]).sole
    assert_equal({ "role" => "assistant", "parts" => [{ "type" => "text", "text" => "Reading the file." }],
                   "phase" => "commentary", "native_origin" => origin }, entry)
    assert_equal [phased], Nexus::InputEntries.from(entries: [entry], workload: "text_generation")

    assert_equal({ "role" => "assistant", "parts" => [{ "type" => "text", "text" => "hi" }] },
      text_message("hi", role: "assistant").to_h, "no phase, no key: the bytes are today's")
  end

  # The one ambiguity `for` creates: a single `{"text" => …}` payload could
  # have been a lone string or a one-element list, and only the workload
  # remembers which.
  test "a single text entry reads back as the shape its workload accepts" do
    entries = Nexus::InputEntries.for("only one")

    assert_equal ["only one"],
      Nexus::InputEntries.from(entries: entries, workload: "embedding")
    assert_equal "only one",
      Nexus::InputEntries.from(entries: entries, workload: "text_generation")
  end

  test "a transcription with no prompt reads back as absent, not as empty text" do
    assert_nil Nexus::InputEntries.from(entries: [], workload: "transcription")
  end

  test "image entries preserve source-image occurrences separately from prompt text" do
    first = SecureRandom.uuid_v7
    second = SecureRandom.uuid_v7
    entries = Nexus::InputEntries.for_image("edit these", upload_public_ids: [second, first, second])

    assert_equal "edit these", Nexus::InputEntries.from(entries: entries, workload: "image_generation")
    assert_equal [second, first, second],
      Nexus::TextInputMessage.from_h(entries.last).parts.map(&:upload_public_id)
    assert_equal Nexus::InputEntries.for("draw this"),
      Nexus::InputEntries.for_image("draw this", upload_public_ids: [])
  end
end
