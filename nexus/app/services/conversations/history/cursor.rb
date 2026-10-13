require "base64"

module Conversations
  module History
    # A keyset over public UUIDs and a closed field name; never an offset or
    # an internal row id. Each page rechecks the caller's current visibility.
    module Cursor
      FIELDS = %w[title prompt content steers].freeze

      def self.encode(row)
        Base64.urlsafe_encode64(JSON.generate(row.values_at("anchor", "conversation_public_id", "field")), padding: false)
      end

      def self.decode(value)
        return nil if value.nil?
        raise Parameters::Invalid, "after is invalid" if value.to_s.bytesize > 256

        decoded = JSON.parse(Base64.urlsafe_decode64(value.to_s))
        entries = Array(decoded)
        unless entries.length == 3 &&
            entries.first(2).all? { |entry| Parameters::UUID.match?(entry.to_s) } && FIELDS.include?(entries.last)
          raise Parameters::Invalid, "after is invalid"
        end
        entries
      rescue JSON::ParserError, ArgumentError
        raise Parameters::Invalid, "after is invalid"
      end
    end
  end
end
