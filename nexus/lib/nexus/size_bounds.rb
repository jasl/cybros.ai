module Nexus
  # Named content bounds: canonical-JSON bytes for structured payloads, UTF-8 bytes for text, counts for
  # ordered children. Oversize is the typed rejection, never truncation; every entry declares its unit and
  # the accessors refuse the wrong one.
  module SizeBounds
    REJECTION = :content_too_large
    COUNT_REJECTION = :content_items_too_many

    BOUNDS = {
      workspace_metadata_bound: { unit: :bytes, value: 2_048 },
      # The override map — the same 2 KiB as the metadata bag, named separately
      # because a change to one must not silently move the other.
      tool_provider_overrides_bound: { unit: :bytes, value: 2_048 },
      conversation_metadata_bound: { unit: :bytes, value: 2_048 },
      speaker_metadata_bound: { unit: :bytes, value: 2_048 },
      envelope_bound: { unit: :bytes, value: 65_536 },
      # A declared tool set aggregates schemas from multiple authorities and
      # environments. Give that set the snapshot-scale storage bound rather
      # than one operation envelope's bound; whole-step/context caps still apply.
      tool_definitions_bound: { unit: :bytes, value: 1_048_576 },
      model_output_schema_bound: { unit: :bytes, value: 16_384 },
      # A store create returns its full snapshot plus the row's envelope.
      workspace_command_response_bound: { unit: :bytes, value: 1_081_344 },
      snapshot_bound: { unit: :bytes, value: 1_048_576 },
      # No compiled-wire bound: wire bytes are compiled in process right before
      # the provider claim and never stored.
      upload_bound: { unit: :bytes, value: 104_857_600 },
      inline_binary_bound: { unit: :bytes, value: 8_388_608 },
      body_upload_bytes_bound: { unit: :bytes, value: 536_870_912 },
      # The Codex authorization wire is bounded before parsing: it runs before
      # any credential exists, so a hostile issuer response must not spend memory.
      # Fail-closed Nexus choices, far above a real token response.
      oauth_exchange_response_bound: { unit: :bytes, value: 65_536 },
      oauth_exchange_field_bound: { unit: :bytes, value: 4_096 },
      # One memory document's text; the same 64 KiB as `envelope_bound`, named
      # separately because a change to one must not silently move the other.
      memory_document_bound: { unit: :bytes, value: 65_536 },
      # One prompt document's text (a slot: system_prompt, character,
      # persona); the same 64 KiB as `memory_document_bound`, named
      # separately because a change to one must not silently move the other.
      prompt_document_bound: { unit: :bytes, value: 65_536 },
      # The environment document an executor announces beside its served list;
      # the same 64 KiB as `envelope_bound`, named separately for the same
      # reason.
      executor_environment_bound: { unit: :bytes, value: 65_536 },
      # The assembly's `skills` block: one line per skill the turn can load,
      # taken in precedence order until the next would cross this bound, the
      # rest named in ONE names-only tail. A BODY bound (the seed's), never
      # a tool-description bound — the same 16 KiB as
      # `MemoryBlock::DEFAULT_BUDGET_BYTES`, the references' one-to-two
      # percent of a 200k window without a context-percent rule the kernel
      # does not have (Claude Code's 1 % / 8 000-character budget is the
      # recorded reference point).
      skill_catalog_bound: { unit: :bytes, value: 16_384 },
      # A STORAGE SANITY BOUND, NEVER A WALL (no cumulative ceilings): sized
      # above what `snapshot_bound` — the composer's byte wall, 1 MiB, the one
      # wall compaction arms on — can hold of the smallest entry the composer
      # writes (a one-character user message, 52 canonical bytes → 20,164
      # entries; 2^15 is the next power of two), so a composed round under the
      # byte wall is never refused for its count: the byte wall fires first and
      # arms compaction. Reachable only by a single body of tiny raw entries (a
      # `{"text":"x"}` input entry is 12 bytes), which is corruption protection.
      # At 256 it was a wall no prune could repair — a cleared result is a
      # placeholder entry, never a removal — and a mainline of small rounds died on
      # it at round 124.
      body_entry_count_bound: { unit: :items, value: 32_768 },
      # The same sanity bound for a body's upload placements, cut from the
      # same wall: an `upload` part is ~60 canonical bytes, so ~17k of them
      # fill `snapshot_bound` before this count can — 2^15, the sibling
      # above. At 32 it was a wall on the composed request: a conversation
      # whose history carried 33 pictures refused its own seal, a shape no
      # prune repairs (the 256-entry precedent).
      body_upload_count_bound: { unit: :items, value: 32_768 },
    }.each_value(&:freeze).freeze

    class << self
      def fetch(name)
        entry(name).fetch(:value)
      end

      def json_bytesize(value)
        CanonicalJson.bytesize(value)
      end

      def json_within?(name, value)
        bytes_within?(name, json_bytesize(value))
      end

      # For a total that is already measured — referenced binary bytes, or a
      # blob size the storage layer reports — rather than a payload to encode.
      def bytes_within?(name, bytes)
        bytes <= expect(name, :bytes)
      end

      def count_within?(name, count)
        count <= expect(name, :items)
      end

      private

        def entry(name)
          BOUNDS.fetch(name)
        end

        def expect(name, expected_unit)
          found = entry(name)
          unless found.fetch(:unit) == expected_unit
            raise ArgumentError, "#{name} is measured in #{found.fetch(:unit)}, not #{expected_unit}"
          end

          found.fetch(:value)
        end
    end
  end
end
