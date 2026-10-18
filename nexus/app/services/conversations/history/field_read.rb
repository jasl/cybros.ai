module Conversations
  module History
    # Saved field text only. Entry reads and returned UTF-8 bytes have separate
    # bounds; a continuation may start inside a single large text part.
    class FieldRead
      ENTRY_LIMIT = 20
      TEXT_BYTES = 16 * 1_024

      def self.call(...) = new(...).call

      def initialize(body:, field:, location: nil, after: nil)
        @body, @field = body, field
        raise Parameters::Invalid, "use only one field cursor" if location && after

        @location = Location.decode(location || after)
        @text = +""
        @next_after = nil
      end

      def call
        if @body
          @field == "steers" ? read_entries : read_projection
        elsif @location
          raise Parameters::Invalid, "location is invalid"
        end
        { text: @text, pagination: { next_after: @next_after } }
      end

      private

        def read_projection
          point = @location || { entry_position: nil, part_index: 0, character_offset: 0 }
          raise Parameters::Invalid, "location is invalid" unless point[:entry_position].nil? && point[:part_index].zero?

          append(@body.readable_text.to_s, point)
        end

        def read_entries
          point = @location || { entry_position: 0, part_index: 0, character_offset: 0 }
          raise Parameters::Invalid, "location is invalid" if point[:entry_position].nil?

          entries = @body.content_body_entries.where("position >= ?", point[:entry_position])
            .reorder(:position).limit(ENTRY_LIMIT).includes(:content_fragment).to_a
          if @location && entries.first&.position != point[:entry_position]
            raise Parameters::Invalid, "location is invalid"
          end
          entries.each do |entry|
            first = entry.position == point[:entry_position]
            parts = @body.search_entry_parts(entry).to_a
            if first && @location && !parts.any? { |part| part.fetch(:part_index) == point[:part_index] }
              raise Parameters::Invalid, "location is invalid" unless point[:part_index].zero? && point[:character_offset].zero?
            end
            parts.each do |part|
              next if first && part.fetch(:part_index) < point[:part_index]

              offset = first && part.fetch(:part_index) == point[:part_index] ? point[:character_offset] : 0
              return if append(part.fetch(:text), part.except(:text).merge(character_offset: offset))
            end
          end
          return if entries.empty?

          next_position = @body.content_body_entries.where("position > ?", entries.last.position).reorder(:position).pick(:position)
          @next_after = Location.encode(entry_position: next_position) if next_position
        end

        def append(text, point)
          offset = point.fetch(:character_offset)
          raise Parameters::Invalid, "location is invalid" if offset > text.length

          separator = @text.empty? ? "" : "\n"
          remaining = TEXT_BYTES - @text.bytesize - separator.bytesize
          piece = remaining.positive? ? text[offset, remaining].byteslice(0, remaining) : ""
          piece = piece.byteslice(0, piece.bytesize - 1) until piece.valid_encoding?
          if piece.empty? && offset < text.length
            @next_after = Location.encode(**point)
            return true
          end
          @text << separator << piece unless piece.empty?
          if offset + piece.length < text.length
            @next_after = Location.encode(**point.merge(character_offset: offset + piece.length))
            return true
          end
          false
        end
    end
  end
end
