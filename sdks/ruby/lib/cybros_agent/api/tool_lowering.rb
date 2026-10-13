module CybrosAgent
  module Api
    # MCP `Tool` → the provider's function entry, and it lives HERE because
    # the specification put it here for the strongest reason in that study:
    # `Tool` is purely ADDITIVE across every MCP revision, so a
    # kernel-side converter would be a standing cache bomb — the deploy
    # that first honours a newly-added field rewrites the front of every
    # live cached prefix with no agent change at all. In the agent's SDK it
    # is a frozen pure function of the `Tool` alone, so a field MCP adds
    # tomorrow moves zero cached bytes until an agent upgrades on purpose.
    #
    # IT COULD NOT HAVE BEEN PASSED THROUGH UNCONVERTED ANYWAY: an
    # MCP-shaped entry is silently DROPPED by the Anthropic and Gemini
    # lanes and 400s on Responses.
    #
    # FIXED KEY ORDER, EVERY OTHER FIELD DROPPED BY CONSTRUCTION, and the
    # model and catalog are never consulted. The tool list is rendered
    # before everything else on the wire, so its bytes are the front of
    # every cached prefix: two callers lowering the same tool must produce
    # the same bytes, and the same caller must produce them again next
    # week. That is why this builds a new Hash in a written order rather
    # than transforming whatever came in.
    module ToolLowering
      # An MCP tool with no schema still takes no arguments — it does not
      # take ARBITRARY ones. Providers require the member, and omitting it
      # is how a model learns it may invent parameters.
      EMPTY_SCHEMA = { "type" => "object", "properties" => {} }.freeze

      module_function

      # `tool` is an MCP `Tool`: a Hash with "name", "description" and
      # "inputSchema", which is exactly what a runner's toolset publishes.
      def function_entry(tool)
        hash = Hash.try_convert(tool)
        raise ArgumentError, "tool must be a Hash, got #{tool.class}" if hash.nil?

        name = hash["name"].to_s
        raise ArgumentError, "tool name is required" if name.empty?

        {
          "type" => "function",
          "function" => {
            "name" => name,
            "description" => hash["description"].to_s,
            "parameters" => schema_of(hash),
          },
        }
      end

      # THE LIST IS A SET, and the kernel canonicalizes it by name on the
      # way in for the same reason: a client that re-authors the same tools
      # in a different order across turns would otherwise bust its own
      # cache. Sorting here means the bytes a caller sends already match
      # the bytes the kernel stores.
      def function_entries(tools)
        Array(tools).map { |tool| function_entry(tool) }
          .sort_by { |entry| entry.fetch("function").fetch("name") }
      end

      def schema_of(hash)
        schema = Hash.try_convert(hash["inputSchema"]) || Hash.try_convert(hash["input_schema"])
        return EMPTY_SCHEMA.dup if schema.nil? || schema.empty?

        schema
      end
    end
  end
end
