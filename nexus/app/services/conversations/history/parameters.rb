module Conversations
  module History
    # Shared HTTP/tool boundary. Values below this point have one shape.
    module Parameters
      class Invalid < StandardError; end
      QUERY_BYTES = 1_024
      MAX_LIMIT = 50
      UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

      def self.search(input)
        query = input.fetch("query", "").to_s.strip
        raise Invalid, "query must contain 1 to #{QUERY_BYTES} UTF-8 bytes" if
          query.empty? || query.bytesize > QUERY_BYTES || !query.valid_encoding? || query.include?("\0")
        archived = input.fetch("archived", "exclude").to_s
        raise Invalid, "archived must be exclude, include or only" unless %w[exclude include only].include?(archived)

        { query: query, archived: archived, include_auxiliary: boolean(input, "include_auxiliary"),
          limit: integer(input, "limit", default: 20, range: 1..MAX_LIMIT), after: input["after"] }
      end

      def self.read(input)
        around = input["around_turn_public_id"]
        raise Invalid, "around_turn_public_id must be a UUID" if around && !UUID.match?(around.to_s)
        after = integer(input, "after_position", range: 0..(2**63 - 1))
        before = integer(input, "before_position", range: 0..(2**63 - 1))
        raise Invalid, "use only one history cursor" if [around, after, before].compact.length > 1

        { around_turn_public_id: around, after_position: after, before_position: before,
          limit: integer(input, "limit", default: 20, range: 1..MAX_LIMIT) }
      end

      def self.integer(input, name, default: nil, range:)
        return default unless input.key?(name)

        raw = input.fetch(name).to_s
        value = Integer(raw, 10, exception: false) if /\A\d+\z/.match?(raw)
        raise Invalid, "#{name} is invalid" unless value && range.cover?(value)

        value
      end

      def self.boolean(input, name)
        value = input.fetch(name, false)
        return true if value == true || value == "true" || value == "1"
        return false if value == false || value == "false" || value == "0"

        raise Invalid, "#{name} must be boolean"
      end
    end
  end
end
