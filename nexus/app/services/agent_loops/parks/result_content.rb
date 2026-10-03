module AgentLoops
  module Parks
    # The grammar belongs to the engine, not either door: MCP supplies the blocks,
    # `outcome` stays ours, and a bare string normalizes to the one entry the engine
    # always wrote — the cache breakpoint.
    class ResultContent
      # The MCP ContentBlock subset carried; a well-formed block of another
      # kind gets its own refusal, distinct from a malformed one.
      KINDS = %w[text resource_link].freeze
      TEXT = "text".freeze
      STRUCTURED = "structured".freeze
      # A CAPTURE the result names: MCP's own `ResourceLink` — `uri` of the
      # ONE scheme the kernel resolves, `nexus://uploads/<id>` (any other
      # scheme is `invalid_content`: an executor materializes what a client
      # should fetch as a capture first), `name` required (MCP
      # `BaseMetadata`); `mimeType`/`size`/`title`/`description` are TYPED
      # and stored verbatim — nothing else is judged (the tool-argument
      # rule). The entry is the block minus its `type`.
      RESOURCE_LINK = "resource_link".freeze
      URI_PREFIX = "nexus://uploads/".freeze
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      LINK_STRINGS = %w[mimeType title description].freeze
      # `Result.resultType` is mandatory on 2026-07-28 and its only other
      # value belongs to MRTR, which we do not implement. Absent reads as
      # "complete", for compatibility with earlier MCP result envelopes.
      DEFAULT_RESULT_TYPE = "complete".freeze
      # Storage's sanity bound (32,768 blocks, above what the byte bound can
      # hold), read from the registry: bounding it here answers 422 rather
      # than a 409 about a payload that will never be accepted.
      MAX_BLOCKS = :body_entry_count_bound

      # `upload_public_ids`: the captures the links name, in block order,
      # each once — what `Settle` resolves as the committer's own.
      Parsed = Data.define(:entries, :refusal, :upload_public_ids) do
        def self.refused(code) = new(entries: [], refusal: code, upload_public_ids: [])
        def self.accepted(entries) = new(entries: entries, refusal: nil, upload_public_ids: link_ids(entries))

        def self.link_ids(entries)
          entries.filter_map { |entry| entry[RESOURCE_LINK]&.fetch("uri")&.delete_prefix(URI_PREFIX) }.uniq
        end

        def accepted? = refusal.nil?
        def empty? = entries.empty?
      end

      class << self
        def call(...) = new(...).parse
      end

      def initialize(content: nil, structured_content: nil, result_type: nil)
        @content = content
        @structured_content = structured_content
        @result_type = result_type
      end

      # Answers the entry list `ContentBodies::Replace` will write, or the
      # engine's typed refusal. Never raises: an unstorable value is the
      # storage guard's answer to give, not this one's.
      def parse
        return refused(:invalid_result_type) unless result_type_accepted?

        blocks = text_entries
        return blocks unless blocks.accepted?

        Parsed.accepted(blocks.entries + structured_entries)
      end

      private

        def refused(code) = Parsed.refused(code)

        def result_type_accepted?
          @result_type.nil? || @result_type == DEFAULT_RESULT_TYPE
        end

        def text_entries
          return Parsed.accepted([]) if @content.nil?

          text = String.try_convert(@content)
          return Parsed.accepted(entry_for(text)) if text

          blocks = Array.try_convert(@content)
          return refused(:invalid_content) if blocks.nil?

          collect(blocks)
        end

        def collect(blocks)
          return refused(:too_many_content_blocks) unless
            Nexus::SizeBounds.count_within?(MAX_BLOCKS, blocks.length)

          entries = []
          blocks.each do |element|
            block = Hash.try_convert(element)
            return refused(:invalid_content) if block.nil?

            kind = String.try_convert(block["type"])
            return refused(:invalid_content) if kind.nil?
            return refused(:unsupported_content_kind) unless KINDS.include?(kind)

            entry = kind == RESOURCE_LINK ? link_entry(block) : text_entry(block)
            return refused(:invalid_content) if entry.nil?

            entries.concat(entry)
          end
          Parsed.accepted(entries)
        end

        def text_entry(block)
          text = String.try_convert(block[TEXT])
          entry_for(text) unless text.nil?
        end

        # nil for a malformed link: the wrong scheme, a non-UUID id, a
        # missing or empty `name`, a mistyped optional field.
        def link_entry(block)
          uri = String.try_convert(block["uri"])
          return nil unless uri&.start_with?(URI_PREFIX) && UUID.match?(uri.delete_prefix(URI_PREFIX))

          name = String.try_convert(block["name"])
          return nil if name.blank?

          link = { "uri" => uri, "name" => name }
          LINK_STRINGS.each do |field|
            next unless block.key?(field)

            value = String.try_convert(block[field])
            return nil if value.nil?

            link[field] = value
          end
          if block.key?("size")
            size = Integer.try_convert(block["size"])
            return nil if size.nil? || size.negative?

            link["size"] = size
          end
          [{ RESOURCE_LINK => link }]
        end

        # A blank block writes no body, as the engine always did; `blank?`,
        # not `empty?`, or a whitespace-only result hands the model
        # canonical entry JSON on the prompt-cache breakpoint.
        def entry_for(text) = text.blank? ? [] : [{ TEXT => text }]

        # THE THREE CHANNELS, one meaning each: `content` is the model's,
        # `structured_content` the UI's, `metadata` the carrier. Structure
        # is stored as its own entry and NEVER serialized into the text
        # position — a result with no text is a result the model reads as
        # `""`, which `Settle` says in the writer's own word
        # (`readable_text`), so the entry JSON never stands in for it. A
        # literal `null` reads as absent.
        def structured_entries
          return [] if @structured_content.nil?

          [{ STRUCTURED => @structured_content }]
        end
    end
  end
end
