module OAuthParameters
  extend ActiveSupport::Concern

  private

    # The transport contract requires duplicate-scalar rejection; empty
    # values are treated as omitted.
    def scalar_field(name)
      # The duplicate counter reads urlencoded and JSON only; any other media
      # would slide duplicates past it, so it is refused before any field read.
      raise OAuth::InvalidRequest if request.post? && !inspectable_media?

      raw = params[name.to_sym]
      value = raw.nil? ? nil : String.try_convert(raw)
      # Arrays/objects where the contract lists a scalar (and any other
      # parameter shape) are malformed transport.
      raise OAuth::InvalidRequest if (!raw.nil? && value.nil?) || duplicated_in_raw?(name)

      value.presence
    end

    def inspectable_media?
      request.media_type.nil? ||
        %w[application/x-www-form-urlencoded application/json].include?(request.media_type)
    end

    def duplicated_in_raw?(name)
      raw_occurrences(name) > 1
    end

    def raw_occurrences(name)
      query = Rack::Utils.parse_query(request.query_string)
      body = request.form_data? ? Rack::Utils.parse_query(request.raw_post) : {}
      field = name.to_s

      form_count = [query, body].sum do |source|
        source.sum do |key, value|
          next 0 unless key == field || key.start_with?("#{field}[")

          value.nil? ? 1 : Array(value).length
        end
      end
      form_count + json_body_occurrences(field)
    end

    # Counted over decoded keys, not source bytes: an escaped spelling is the
    # same key after decoding, and a text scan failed open on it.
    def json_body_occurrences(field)
      return 0 unless request.media_type == "application/json"

      root = parsed_json_root
      (root.key?(field) ? 1 : 0) + root.duplicate_count(field)
    end

    # Always a DuplicateRecordingObject: a non-object or malformed body
    # parses to an EMPTY one (no keys, no duplicates), so the caller reads a
    # uniform shape without probing its type.
    def parsed_json_root
      @parsed_json_root ||= parse_json_root
    end

    def parse_json_root
      parsed = JSON.parse(request.raw_post, object_class: DuplicateRecordingObject)
      # Normalized to a Hash at the boundary: try_convert returns the parsed
      # object itself when it is one (duplicate state intact) and nil for a
      # non-object root, which needs no scalar dedup anyway.
      Hash.try_convert(parsed) || DuplicateRecordingObject.new
    rescue JSON::ParserError
      DuplicateRecordingObject.new
    end

    # Every assignment to a name the parser already holds is a duplicate it
    # would otherwise collapse to last-wins; a key-shaped string in a value never counts.
    class DuplicateRecordingObject < Hash
      def []=(key, value)
        @duplicates ||= Hash.new(0)
        @duplicates[key] += 1 if key?(key)
        super
      end

      def duplicate_count(key) = (@duplicates ||= Hash.new(0))[key.to_s]
    end
end
