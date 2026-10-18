require "base64"

module Conversations
  module History
    # Coordinates within one exact variant field, never row identities or
    # authorization. A nil entry addresses the body's stored text projection.
    module Location
      def self.encode(entry_position: nil, part_index: 0, character_offset: 0)
        Base64.urlsafe_encode64(JSON.generate([entry_position, part_index, character_offset]), padding: false)
      end

      def self.decode(value)
        return nil if value.nil?
        raise Parameters::Invalid, "location is invalid" if value.to_s.bytesize > 256

        entries = Array(JSON.parse(Base64.urlsafe_decode64(value.to_s)))
        unless entries.length == 3 && (entries.first.nil? || coordinate?(entries.first)) &&
            entries.drop(1).all? { |entry| coordinate?(entry) }
          raise Parameters::Invalid, "location is invalid"
        end
        { entry_position: entries.first&.to_i, part_index: entries[1].to_i, character_offset: entries[2].to_i }
      rescue JSON::ParserError, ArgumentError
        raise Parameters::Invalid, "location is invalid"
      end

      def self.coordinate?(value)
        /\A\d+\z/.match?(value.to_s) && value.to_s.to_i <= 2**63 - 1
      end
      private_class_method :coordinate?
    end
  end
end
