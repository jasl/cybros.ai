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

      # `columns` maps ordered key columns to their shape (:uuid, :text or :timestamp) as code
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
          next_after: overflow ? encode_cursor(rows.last, columns, direction) : nil,
        )
      end

      def list_limit
        limit_param(default: DEFAULT_LIST_LIMIT, max: LIST_LIMIT_RANGE.end)
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

          shape == :timestamp ? Time.iso8601(value) : value
        end
      rescue ArgumentError, JSON::ParserError
        raise APIErrors::ParameterInvalid, :after
      end

      def after_condition(scope, keys, values, direction)
        scope.where(keyset_predicate(scope.klass.arel_table, keys, values, direction))
      end

      # Every key is non-null and ordered in the same direction. Row comparison
      # lets PostgreSQL seek the compound index at the cursor instead of scanning
      # and filtering the preceding pages. Keep column names and values in Arel.
      def keyset_predicate(table, keys, values, direction)
        columns = Arel::Nodes::Grouping.new(keys.map { |key| table[key] })
        boundary = Arel::Nodes::Grouping.new(
          keys.zip(values).map { |key, value| Arel::Nodes.build_quoted(value, table[key]) }
        )
        direction == :desc ? columns.lt(boundary) : columns.gt(boundary)
      end

      def encode_cursor(row, columns, direction)
        payload = columns.to_h do |key, shape|
          value = row.public_send(key)
          # PostgreSQL timestamps retain microseconds. The ordinary JSON
          # rendering truncates them and would repeat or skip a boundary row.
          [key.to_s, shape == :timestamp ? value.iso8601(6) : value]
        end
        Base64.urlsafe_encode64(
          JSON.generate(payload.merge(CURSOR_DIRECTION_KEY => direction.to_s)), padding: false
        )
      end
  end
end
