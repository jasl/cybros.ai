module AgentAPI
  # The family's keyset grammar: an opaque urlsafe-base64 JSON cursor carrying the
  # last row's key values and `pagination.next_after`. A cursor that does not
  # decode to this list's key shape is 400 parameter_invalid.
  module KeysetPagination
    Page = Data.define(:records, :next_after)

    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    DEFAULT_LIST_LIMIT = 25
    LIST_LIMIT_RANGE = (1..100)
    # Ascending by default (what every shipped client reads); `order=desc` runs
    # over this list's key columns, so a name-keyed list reverses alphabetically.
    DIRECTIONS = { "asc" => :asc, "desc" => :desc }.freeze
    # The cursor CARRIES its direction. A page taken one way and continued
    # the other walks back over what the caller already has, forever.
    CURSOR_DIRECTION_KEY = "dir".freeze

    private

      # `columns` maps ordered key columns to their shape (:uuid or :text) as code
      # literals. The order is this method's: a caller-ordered scope could
      # disagree with the cursor it hands back.
      def keyset_page(scope, columns:)
        limit = list_limit
        direction = list_direction
        values = decoded_cursor(columns, direction)
        scope = scope.order(columns.keys.to_h { |key| [key, direction] })
        scope = after_condition(scope, columns.keys, values, direction) if values
        rows = scope.limit(limit + 1).to_a
        overflow = rows.length > limit
        rows = rows.first(limit)

        Page.new(
          records: rows,
          next_after: overflow ? encode_cursor(rows.last, columns.keys, direction) : nil,
        )
      end

      def list_limit
        if params[:limit].nil?
          DEFAULT_LIST_LIMIT
        else
          requested = bounded_integer(params[:limit], :limit, range: (LIST_LIMIT_RANGE.begin..))
          requested.clamp(..LIST_LIMIT_RANGE.end)
        end
      end

      def list_direction
        raw = params[:order]
        return :asc if raw.blank?

        DIRECTIONS.fetch(raw.to_s) { raise APIErrors::ParameterInvalid, :order }
      end

      def decoded_cursor(columns, direction)
        raw = params[:after]
        return nil if raw.blank?

        raw = raw.to_s

        decoded = JSON.parse(Base64.urlsafe_decode64(raw))
        decoded = Hash.try_convert(decoded)
        raise APIErrors::ParameterInvalid, :after if decoded.nil?
        carried = decoded.delete(CURSOR_DIRECTION_KEY)
        # Continuing a page the other way is refused rather than silently
        # walking back over rows the caller already has.
        raise APIErrors::ParameterInvalid, :after if carried != direction.to_s
        raise APIErrors::ParameterInvalid, :after unless decoded.keys.sort == columns.keys.map(&:to_s).sort

        columns.map do |column, shape|
          value = String.try_convert(decoded.fetch(column.to_s))
          raise APIErrors::ParameterInvalid, :after if value.nil?
          raise APIErrors::ParameterInvalid, :after if shape == :uuid && !value.match?(UUID_FORMAT)

          value
        end
      rescue ArgumentError, JSON::ParserError
        raise APIErrors::ParameterInvalid, :after
      end

      def after_condition(scope, keys, values, direction)
        scope.where(keyset_predicate(scope.klass.arel_table, keys, values, direction))
      end

      # (a, b) > (x, y) expanded as a > x OR (a = x AND b > y), recursively —
      # pure Arel, so no SQL text is ever assembled from key names. Descending
      # is the same walk with the comparison reversed.
      def keyset_predicate(table, keys, values, direction)
        key, *rest_keys = keys
        value, *rest_values = values
        beyond = direction == :desc ? table[key].lt(value) : table[key].gt(value)
        return beyond if rest_keys.empty?

        beyond.or(
          table[key].eq(value).and(keyset_predicate(table, rest_keys, rest_values, direction))
        )
      end

      def encode_cursor(row, keys, direction)
        payload = keys.to_h { |key| [key.to_s, row.public_send(key)] }
        Base64.urlsafe_encode64(
          JSON.generate(payload.merge(CURSOR_DIRECTION_KEY => direction.to_s)), padding: false
        )
      end
  end
end
