require "test_helper"

class Nexus::SizeBoundsTest < ActiveSupport::TestCase
  test "v1 registry holds exactly the landed bounds, each declaring its unit" do
    assert_equal(
      {
        workspace_metadata_bound: { unit: :bytes, value: 2_048 },
        tool_provider_overrides_bound: { unit: :bytes, value: 2_048 },
        conversation_metadata_bound: { unit: :bytes, value: 2_048 },
        speaker_metadata_bound: { unit: :bytes, value: 2_048 },
        envelope_bound: { unit: :bytes, value: 65_536 },
        tool_definitions_bound: { unit: :bytes, value: 1_048_576 },
        model_output_schema_bound: { unit: :bytes, value: 16_384 },
        workspace_command_response_bound: { unit: :bytes, value: 1_081_344 },
        snapshot_bound: { unit: :bytes, value: 1_048_576 },
        upload_bound: { unit: :bytes, value: 104_857_600 },
        inline_binary_bound: { unit: :bytes, value: 8_388_608 },
        body_upload_bytes_bound: { unit: :bytes, value: 536_870_912 },
        oauth_exchange_response_bound: { unit: :bytes, value: 65_536 },
        oauth_exchange_field_bound: { unit: :bytes, value: 4_096 },
        memory_document_bound: { unit: :bytes, value: 65_536 },
        prompt_document_bound: { unit: :bytes, value: 65_536 },
        executor_environment_bound: { unit: :bytes, value: 65_536 },
        # The skills block's body bound: the memory budget's order, one names-only tail past it.
        skill_catalog_bound: { unit: :bytes, value: 16_384 },
        body_entry_count_bound: { unit: :items, value: 32_768 },
        # The same sanity bound for a body's upload placements: an upload part is ~60 canonical
        # bytes, so the byte wall fills long before this count — never a wall on a composed request.
        body_upload_count_bound: { unit: :items, value: 32_768 },
      },
      Nexus::SizeBounds::BOUNDS
    )
    assert_predicate Nexus::SizeBounds::BOUNDS, :frozen?
    assert Nexus::SizeBounds::BOUNDS.each_value.all?(&:frozen?)
  end

  # Two bounds lived here for the SECOND body admission sealed so send time
  # could prove it had not drifted: a byte bound above the accepted body's,
  # and an entry reserve acceptance held back against it. Stage 3 deleted that
  # body — the prepared request is built immediately before IO and never
  # stored — so nothing is bounded or reserved on its behalf.
  test "nothing is bounded or reserved for a request nothing stores" do
    assert_raises(KeyError) { Nexus::SizeBounds.fetch(:compiled_request_bound) }
    assert_raises(KeyError) { Nexus::SizeBounds.fetch(:compiled_request_entry_reserve) }
  end

  test "fetch resolves a named bound and rejects an unregistered name" do
    assert_equal 2_048, Nexus::SizeBounds.fetch(:workspace_metadata_bound)
    assert_equal 104_857_600, Nexus::SizeBounds.fetch(:upload_bound)
    assert_equal 16_384, Nexus::SizeBounds.fetch(:model_output_schema_bound)
    assert_equal 32_768, Nexus::SizeBounds.fetch(:body_entry_count_bound)
    assert_raises KeyError do
      Nexus::SizeBounds.fetch(:no_such_bound)
    end
  end

  # Provider requests embed prepared binary bytes inline. Upload and inline-binary limits apply
  # independently, so the effective bound is their minimum.
  test "inline_binary_bound is registered as a byte bound below upload_bound" do
    assert_equal 8_388_608, Nexus::SizeBounds.fetch(:inline_binary_bound)
    assert_operator Nexus::SizeBounds.fetch(:inline_binary_bound), :<,
                    Nexus::SizeBounds.fetch(:upload_bound)
  end

  # The unit is the point of the registry: a byte accessor must refuse a count bound and a count
  # accessor must refuse a byte bound, so no boundary can silently measure the wrong dimension.
  test "typed accessors require the bound's declared unit" do
    assert_raises ArgumentError do
      Nexus::SizeBounds.json_within?(:body_entry_count_bound, { "k" => 1 })
    end
    assert_raises ArgumentError do
      Nexus::SizeBounds.count_within?(:envelope_bound, 1)
    end
    assert_raises ArgumentError do
      Nexus::SizeBounds.bytes_within?(:body_entry_count_bound, 1)
    end
  end

  test "the two typed rejections name their own dimension" do
    assert_equal :content_too_large, Nexus::SizeBounds::REJECTION
    assert_equal :content_items_too_many, Nexus::SizeBounds::COUNT_REJECTION
  end

  test "count_within? measures items against the named count bound exactly" do
    assert Nexus::SizeBounds.count_within?(:body_entry_count_bound, 32_768)
    assert_not Nexus::SizeBounds.count_within?(:body_entry_count_bound, 32_769)
    assert Nexus::SizeBounds.count_within?(:body_upload_count_bound, 32_768)
    assert_not Nexus::SizeBounds.count_within?(:body_upload_count_bound, 32_769)
  end

  # THE COUNT IS A STORAGE SANITY BOUND, NEVER A SECOND REQUEST LIMIT. A composed round is
  # bounded by `snapshot_bound`'s bytes — the one wall compaction arms on —
  # and the entry count must sit ABOVE what those bytes can hold of the
  # smallest entry the composer writes, or it is a second wall no prune
  # can repair (a cleared result is a placeholder entry, never a removal).
  # The smallest entry is re-derived here through the composer's own
  # measure, so the pin moves if the entry shape ever does.
  test "the entry count bound sits above what the byte wall can hold of the smallest composed entry" do
    smallest = Nexus::TextInputMessage.new(
      role: "user", parts: [Nexus::TextInputPart.new(type: "text", text: "x")]
    )
    bytes = Nexus::CanonicalJson.bytesize(Nexus::InputEntries.for([smallest]).sole)
    most_entries_under_the_wall = Nexus::SizeBounds.fetch(:snapshot_bound) / bytes

    assert_equal 52, bytes, "a one-character user message, canonical"
    assert_equal 20_164, most_entries_under_the_wall, "the 20,165th entry crosses the wall"
    assert_operator Nexus::SizeBounds.fetch(:body_entry_count_bound), :>, most_entries_under_the_wall,
      "a composed round under the byte wall is never refused for its count"
  end

  # Referenced binary bytes are already known integers by the time a body is
  # formed, so the aggregate check takes a measured total rather than a payload.
  test "bytes_within? measures an already-known byte total" do
    assert Nexus::SizeBounds.bytes_within?(:upload_bound, 104_857_600)
    assert_not Nexus::SizeBounds.bytes_within?(:upload_bound, 104_857_601)
    assert Nexus::SizeBounds.bytes_within?(:body_upload_bytes_bound, 536_870_912)
    assert_not Nexus::SizeBounds.bytes_within?(:body_upload_bytes_bound, 536_870_913)
  end

  test "json_within? measures canonical JSON bytes against the named bound exactly" do
    # {"k":"<filler>"} costs 8 framing bytes, so the filler below lands the
    # canonical encoding exactly on the bound.
    at_bound = { "k" => "a" * (65_536 - 8) }
    over_bound = { "k" => "a" * (65_536 - 7) }

    assert Nexus::SizeBounds.json_within?(:envelope_bound, at_bound)
    assert_not Nexus::SizeBounds.json_within?(:envelope_bound, over_bound)
  end

  test "json sizing is canonical, so key order cannot change a verdict" do
    filler = "a" * (65_536 - 20)
    first = { "bb" => filler, "a" => 1 }
    second = { "a" => 1, "bb" => filler }

    assert_equal(
      Nexus::SizeBounds.json_bytesize(first),
      Nexus::SizeBounds.json_bytesize(second)
    )
  end

  # `unit`, `text_within?`, and `text_bytesize` went with the 2026-08-15 sweep:
  # three of the four typed accessors ship (json/bytes/count), and the text one
  # never had a caller. Its UTF-8 pin went with it — there is no subject left
  # to measure, and String#bytesize is not ours to test.
end
