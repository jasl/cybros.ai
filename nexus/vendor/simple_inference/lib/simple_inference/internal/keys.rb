module SimpleInference
  module Internal
    # The gem's ONE home for hash key-shape conversion.
    #
    # KEY-TYPE CONTRACT: the gem spans three worlds, each with exactly one key
    # type — Ruby-side option bags use SYMBOL keys (normalized once, shallowly,
    # at the boundary; nested payload values are opaque and never reshaped);
    # wire-bound and wire-derived payloads use STRING keys all the way down;
    # the adapter envelope uses symbol keys consumed with strict fetch. Every
    # conversion between those worlds goes through this module, so no protocol
    # carries its own (subtly divergent) copy: before consolidation the gem had
    # 19 private helpers across 11 files, including two byte-identical twins in
    # one file and two SAME-NAMED helpers with DIFFERENT semantics in two files.
    module Keys
      module_function

      # Shallow symbol keys for a Ruby-side option bag. Values pass through by
      # reference — nested payloads are opaque; nil reads as an empty bag.
      def shallow_symbolize(value)
        value.to_h.transform_keys(&:to_sym)
      end

      # Shallow string keys for a wire-adjacent hash whose values are opaque;
      # nil reads as an empty hash.
      def shallow_stringify(value)
        value.to_h.transform_keys(&:to_s)
      end

      # Normalize a wire-bound/wire-derived structure to STRING keys throughout:
      # hashes recurse, hash elements of arrays recurse, all other values pass
      # through by reference; nil reads as {}.
      def deep_stringify(value)
        value.to_h.to_h { |key, entry| [key.to_s, deep_stringify_entry(entry)] }
      end

      # A JSON value is the one real union here: object, array or scalar.
      def deep_stringify_entry(entry)
        case entry
        when Hash
          deep_stringify(entry)
        when Array
          entry.map { |item| deep_stringify_entry(item) }
        else
          entry
        end
      end
    end
  end
end
