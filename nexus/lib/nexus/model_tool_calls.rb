module Nexus
  # The one normalizer for provider tool calls: both wire spellings flatten to
  # {"id", "name", "arguments", "ordinal"} with arguments a JSON string; call_id
  # wins over item id; junk is skipped, never guessed; ordinal is encounter order.
  module ModelToolCalls
    FORMAT = "nexus.tool_calls.v1".freeze
    # A pairing key the kernel mints when the provider sent none (Gemini emits
    # parallel calls without ids). The prefix keeps it distinguishable and the
    # ordinal keeps it deterministic, so a retried round recomposes to the same bytes.
    SYNTHETIC_ID_PREFIX = "nx_call_".freeze
    # The longest pairing key a call's row can hold: the node column that
    # stores it is string(128).
    MAX_ID_LENGTH = 128

    module_function

    # The provider's tool calls enter the kernel here, once: an entry is a
    # call object (flat or nested under "function") or junk that is skipped.
    def normalize(tool_calls)
      claimed = {}
      Array(tool_calls).each_with_index.filter_map do |call, index|
        entry = Hash.try_convert(call)
        next if entry.nil?

        function = entry["function"] || {}
        name = (function["name"] || entry["name"]).to_s
        next if name.empty?

        {
          "id" => pairing_key(entry, index, claimed),
          "name" => name,
          "arguments" => arguments_string(function["arguments"] || entry["arguments"]),
          "ordinal" => index,
        }
      end
    end

    # The wire spells arguments as JSON text or as the parsed object.
    def arguments_string(arguments)
      case arguments
      when String then arguments
      when nil then "{}"
      else JSON.generate(arguments)
      end
    end

    # Unique, always: a repeated provider id would hand both calls one result
    # under the last-wins index, so the second occurrence is disambiguated.
    # And storable: the key is written to the call's row, and a row that
    # cannot be stored raises inside the converger, which meets the same
    # round again on every wake. So a key past MAX_ID_LENGTH — the
    # provider's own, or one the disambiguation lengthened — is the key the
    # kernel mints instead; the replayed call and its result carry it alike.
    def pairing_key(entry, index, claimed)
      given = (entry["call_id"] || entry["id"]).to_s
      minted = "#{SYNTHETIC_ID_PREFIX}#{index}"
      key = given.empty? || given.length > MAX_ID_LENGTH ? minted : given
      key = "#{key}#{minted}" if claimed.key?(key)
      key = minted if key.length > MAX_ID_LENGTH
      claimed[key] = true
      key
    end

    # The stored envelope, one sealed entry beside the response body —
    # versioned like the reasoning trace so a reader can refuse a shape it
    # does not know instead of guessing.
    def envelope(tool_calls)
      items = normalize(tool_calls)
      return nil if items.empty?

      { "type" => "tool_calls", "format" => FORMAT, "items" => items }
    end
  end
end
