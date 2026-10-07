module CybrosAgent
  module Api
    # Strict success-shape reading, shared by the clients and
    # the typed resources: a 2xx whose payload breaks the resource contract is
    # MalformedResponse right here, never a nil chain three call frames later.
    # THE ONE VALUE BUILDER: a value is built from its TYPED MAP — `member => reader` — over
    # the readers below, the Data's own keyword `new` as the codec. A projection module
    # keeps the maps of the values it serves in its `SHAPES`, and the map for a class is
    # found through the include chain the way a method is. A reader is one of::string — this
    # module's reader, the member's name as the wire key [:string, "a", "b"] — the same
    # reader down a path of guaranteed objects [:shape, Klass, *path] — a nested value
    # (`optional_shape`, `shapes`, … likewise) ->(hash) { … } — the odd member, a lambda
    # over the readers The wire is the ONE place a value's type is probed; a value these
    # readers built is never re-probed downstream.
    module Parsing
      private

        def shape(klass, hash, key = nil)
          hash = key.nil? ? hash_item(hash, "response") : fetch_hash(hash, key)
          map = shape_map(klass)
          klass.new(**map.to_h { |member, reader| [member, member_value(hash, member, reader)] })
        end

        def optional_shape(klass, hash, key)
          nested = optional_hash(hash, key)
          nested.nil? ? nil : shape(klass, nested)
        end

        # Absent reads as the value's own EMPTY form — the compacted
        # envelope's rule: a member the presenter dropped for having no
        # content is a fact with no content, never a missing fact.
        def shape_or_empty(klass, hash, key)
          shape(klass, optional_hash(hash, key) || {})
        end

        def shapes(klass, hash, key)
          fetch_array(hash, key).map { |item| shape(klass, hash_item(item, key)) }.freeze
        end

        def optional_shapes(klass, hash, key)
          hash[key].nil? ? nil : shapes(klass, hash, key)
        end

        def shapes_or_empty(klass, hash, key)
          hash[key].nil? ? [].freeze : shapes(klass, hash, key)
        end

        # The manual Page envelope: the typed items under
        # `key` and the cursor, which the wire always carries — null when
        # the collection is exhausted.
        def page(klass, body, key)
          Page.new(
            items: shapes(klass, body, key),
            next_after: nullable_string(fetch_hash(body, "pagination"), "next_after")
          )
        end

        def shape_map(klass)
          self.class.ancestors.each do |mod|
            next unless mod.const_defined?(:SHAPES, false)
            return mod::SHAPES.fetch(klass) if mod::SHAPES.key?(klass)
          end
          raise ArgumentError, "#{self.class} serves no #{klass}"
        end

        def member_value(hash, member, reader)
          case reader
          in Proc then instance_exec(hash, &reader)
          in Symbol then send(reader, hash, member.to_s)
          in [Symbol => name, Class => klass, *path]
            send(name, klass, *located(hash, path.empty? ? [member.to_s] : path))
          in [Symbol => name, *path] then send(name, *located(hash, path))
          else raise ArgumentError, "#{member}: not a reader: #{reader.inspect}"
          end
        end

        # A path names guaranteed objects down to its last key.
        def located(hash, path)
          *steps, key = path
          [steps.reduce(hash) { |node, step| fetch_hash(node, step) }, key]
        end

        # ---- THE READERS: one per wire shape, each the one probe of it ----

        def fetch_hash(body, key)
          value = body.is_a?(Hash) ? body[key] : nil
          raise MalformedResponse, "expected #{key} object" unless value.is_a?(Hash)

          value
        end

        def optional_hash(hash, key)
          value = hash[key]
          return nil if value.nil?
          raise MalformedResponse, "expected #{key} object" unless value.is_a?(Hash)

          value
        end

        def hash_item(item, key)
          raise MalformedResponse, "expected #{key} object" unless item.is_a?(Hash)

          item
        end

        def fetch_array(body, key)
          value = body.is_a?(Hash) ? body[key] : nil
          raise MalformedResponse, "expected #{key} array" unless value.is_a?(Array)

          value
        end

        def string(hash, key)
          value = hash[key]
          raise MalformedResponse, "expected #{key} string" unless value.is_a?(String) && !value.empty?

          value
        end

        def optional_string(hash, key)
          value = hash[key]
          return nil if value.nil?
          raise MalformedResponse, "expected #{key} string" unless value.is_a?(String)

          value
        end

        # Present on the wire, null allowed: a member the server always
        # states, even when it states nothing.
        def nullable_string(hash, key)
          raise MalformedResponse, "expected #{key}" unless hash.key?(key)

          optional_string(hash, key)
        end

        def string_list(hash, key)
          value = fetch_array(hash, key)
          raise MalformedResponse, "expected #{key} string list" unless value.all?(String)

          json_snapshot(value)
        end

        # A list of names, or absent; a member the server reported in the
        # wrong type is still MalformedResponse.
        def optional_string_list(hash, key)
          hash[key].nil? ? nil : string_list(hash, key)
        end

        # Names read LENIENTLY: the trace compacts an empty key list away.
        def names(hash, key)
          Array(hash[key]).map(&:to_s).freeze
        end

        def numbers(hash, key)
          value = fetch_array(hash, key)
          raise MalformedResponse, "expected #{key} numeric list" unless value.all?(Numeric)

          value.freeze
        end

        def integer(hash, key)
          value = hash[key]
          raise MalformedResponse, "expected #{key} integer" unless value.is_a?(Integer)

          value
        end

        # THE COMPACTED-ENVELOPE READERS. Usage and timing drop every member
        # the provider had no number for, so absent and null are the same
        # statement — "not reported" — and both become nil. A member the
        # server DID report in the wrong type is still MalformedResponse.
        def optional_integer(hash, key)
          value = hash[key]
          return nil if value.nil?
          raise MalformedResponse, "expected #{key} integer" unless value.is_a?(Integer)

          value
        end

        # A counter compacted away when zero.
        def count(hash, key)
          hash[key].to_i
        end

        def optional_number(hash, key)
          value = hash[key]
          return nil if value.nil?
          raise MalformedResponse, "expected #{key} number" unless value.is_a?(Numeric)

          value
        end

        def boolean(hash, key)
          value = hash[key]
          raise MalformedResponse, "expected #{key} boolean" unless value == true || value == false

          value
        end

        def optional_boolean(hash, key)
          value = hash[key]
          return nil if value.nil?
          raise MalformedResponse, "expected #{key} boolean" unless value == true || value == false

          value
        end

        # A mark compacted away when false.
        def flag(hash, key)
          hash[key] == true
        end

        # Verbatim and unshaped: a tool's own output, a cursor the caller
        # hands back.
        def raw(hash, key)
          hash[key]
        end

        # ---- OPAQUE JSON, snapshotted: any value, an object, a list ----

        def json(hash, key)
          json_snapshot(hash[key])
        end

        # Present on the wire, null allowed — a stored JSON null is a value.
        def nullable_json(hash, key)
          raise MalformedResponse, "expected #{key}" unless hash.key?(key)

          json_snapshot(hash[key])
        end

        def json_object(hash, key)
          json_snapshot(fetch_hash(hash, key))
        end

        def optional_json_object(hash, key)
          json_snapshot(optional_hash(hash, key))
        end

        def json_object_or_empty(hash, key)
          json_snapshot(optional_hash(hash, key) || {})
        end

        def json_array(hash, key)
          json_snapshot(fetch_array(hash, key))
        end

        def optional_json_array(hash, key)
          hash[key].nil? ? nil : json_array(hash, key)
        end

        def json_array_or_empty(hash, key)
          hash[key].nil? ? [].freeze : json_array(hash, key)
        end

        # An opaque-JSON snapshot: recursively copied and frozen on the way
        # into a value object, so a later mutation of the parsed response — or
        # of the value's own tree — can never make the object disagree with
        # what the server said.
        def json_snapshot(value)
          case value
          when Hash
            value.to_h { |key, item| [json_snapshot(key), json_snapshot(item)] }.freeze
          when Array
            value.map { |item| json_snapshot(item) }.freeze
          when String
            value.frozen? ? value : value.dup.freeze
          else
            value
          end
        end
    end
  end
end
