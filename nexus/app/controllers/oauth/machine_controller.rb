# The OAuth machine endpoints: form in, JSON out, no cookies or CSRF state;
# every response non-cacheable and errors in the top-level OAuth envelope.
class OAuth::MachineController < ActionController::API
  include RateLimitedResponse

  before_action :set_no_store

  rescue_from ActionDispatch::Http::Parameters::ParseError, with: -> { render_oauth_error(:invalid_request) }

  private

    # `Pragma` is RFC 6749 §5.1's own ask on the token endpoint.
    def set_no_store
      no_store
      response.headers["Pragma"] = "no-cache"
    end

    def render_oauth_error(code, status: :bad_request)
      render json: { error: code.to_s }, status: status
    end

    def render_rate_limit_error
      render_oauth_error(:temporarily_unavailable, status: :too_many_requests)
    end

    # The transport contract requires duplicate-scalar rejection; empty
    # values are treated as omitted.
    def scalar_field(name)
      # The duplicate counter reads urlencoded and JSON only; any other media
      # would slide duplicates past it, so it is refused before any field read.
      raise OAuth::InvalidRequest if request.post? && !inspectable_media?

      case value = params[name.to_sym]
      when nil, String
        raise OAuth::InvalidRequest if duplicated_in_raw?(name)

        value.presence
      else
        # Arrays/objects where the contract lists a scalar (and any other
        # parameter shape) are malformed transport.
        raise OAuth::InvalidRequest
      end
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

          case value
          when Array then value.length
          else 1
          end
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
