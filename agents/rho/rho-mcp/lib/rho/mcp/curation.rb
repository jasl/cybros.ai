require "json"
require "cybros_agent"
require "rho/runner"

module Rho
  module Mcp
    # THE ANNOUNCEMENT: each allowed tool becomes a
    # tool CLASS at load — NAME by `Naming.tool`, DESCRIPTION and SCHEMA
    # VERBATIM (every byte the server sent; a description is model-facing
    # and load-bearing, and an invented sentence would be ours in the
    # server's mouth), EFFECT_PROFILE the WORST honest case unless the
    # operator's `effect_profiles` row replaces it (the operator's act,
    # validated by value at parse), TIMEOUT_MS the row's, INTERNAL_CLAMP
    # always (the announced park is the wall; the runner never asks the
    # kernel for more on a third party's behalf). `annotations` are never
    # read: MCP's own text calls them untrusted.
    #
    # Curation is EXPLICIT: a name the allowlist named that the server did
    # not list is that server's runtime fault (the list is stale; nothing
    # of it is announced — a partial announcement would be a silent one);
    # so is an allowlisted tool with no description (the door refuses an
    # empty one, and an invented sentence would be ours). Under `"*"` a
    # tool with no description is skipped and listed; a schema
    # json_schemer refuses is skipped and listed under either. The bytes
    # per tool are the lowered entry's — what the model receives.
    module Curation
      WORST_CASE = {
        "kind" => "write", "destructive" => true, "world" => "open",
        "idempotency" => "none", "reconciliation" => "none",
      }.freeze
      NO_DESCRIPTION = "has no description; the model could not choose it".freeze

      # One announced tool: the class and the facts `rho mcp` prints.
      Announced = Data.define(:public_name, :raw_name, :bytes, :profile, :profile_source, :klass, :description, :schema)
      Skipped = Data.define(:raw_name, :reason)
      # `fault` set = the row is down (nothing announced); else the classes.
      Curated = Data.define(:announced, :skipped, :fault) do
        def classes = announced.map(&:klass)
        def bytes = announced.sum(&:bytes)
      end

      module_function

      # `tools` are `MCP::Client::Tool`s (or anything answering `name`,
      # `description`, `input_schema`); `caller` is what a class's `call`
      # invokes: `(server_key, raw_name, args, env:, public_name:)`.
      def curate(row, tools, caller: Rho::Mcp.method(:call))
        listed = Array(tools)
        names = listed.map { |tool| tool.name.to_s }
        doubled = names.tally.find { |_name, count| count > 1 }
        return down(row, "tools/list names #{doubled.first.inspect} twice") if doubled

        unless row.all_tools?
          missing = row.tools - names
          unless missing.empty?
            return down(row, "tools names #{missing.map(&:inspect).join(", ")}, which the server did not list " \
                             "(it lists: #{names.join(", ")})")
          end
        end

        announced = []
        skipped = []
        listed.each do |tool|
          raw = tool.name.to_s
          unless row.allows?(raw)
            skipped << Skipped.new(raw_name: raw, reason: "not in tools")
            next
          end

          public_name = Naming.tool(row.key, raw)
          reason = reason_to_skip(tool, public_name)
          if reason
            return down(row, reason) if !row.all_tools? && reason.end_with?(NO_DESCRIPTION)

            skipped << Skipped.new(raw_name: raw, reason: reason)
            next
          end

          announced << announce(row, tool, public_name, caller)
        end
        Curated.new(announced: announced.freeze, skipped: skipped.freeze, fault: nil)
      end

      def down(row, reason)
        Curated.new(announced: [], skipped: [], fault: "mcp server \"#{row.key}\": #{reason}")
      end

      def reason_to_skip(tool, public_name)
        return "#{public_name} #{NO_DESCRIPTION}" if tool.description.to_s.strip.empty?

        schema = Hash.try_convert(tool.input_schema)
        return "#{public_name}'s schema is not a JSON Schema object" unless schema && schema["type"] == "object"

        Rho::Runner::InputSchema.compile(schema)
        nil
      rescue ArgumentError => error
        "#{public_name}'s schema was refused: #{error.message}"
      end

      def announce(row, tool, public_name, caller)
        raw = tool.name.to_s
        override = row.effect_profiles[raw]
        profile = (override || WORST_CASE).freeze
        description = tool.description.to_s.dup.freeze
        # The server's schema as it came off the wire: a JSON round trip is
        # the private copy (string keys, fresh strings) made shareable.
        schema = Ractor.make_shareable(JSON.parse(JSON.generate(tool.input_schema)))
        klass = tool_class(row, raw, public_name, description, schema, profile, caller)
        Announced.new(
          public_name: public_name, raw_name: raw, bytes: bytes(public_name, description, schema),
          profile: profile, profile_source: (override ? "operator" : "worst case"), klass: klass,
          description: description, schema: schema
        )
      end

      # The bytes the model receives: the SDK's frozen lowering of the
      # declaration, one function entry.
      def bytes(public_name, description, schema)
        entry = CybrosAgent::Api::ToolLowering.function_entry(
          "name" => public_name, "description" => description, "inputSchema" => schema
        )
        JSON.generate(entry).bytesize
      end

      # The class closes over `(server_key, raw_name)` and nothing else: the
      # registry builds one instance per toolset — one per placement (a
      # conversation's root set), and a new one for placement zero when the
      # default root moves — so a connection hung off a tool would die at
      # every placement.
      def tool_class(row, raw, public_name, description, schema, profile, caller)
        server_key = row.key
        Class.new do
          const_set(:NAME, public_name)
          const_set(:DESCRIPTION, description)
          const_set(:SCHEMA, schema)
          const_set(:EFFECT_PROFILE, profile)
          const_set(:TIMEOUT_MS, row.timeout_ms) unless row.timeout_ms.nil?
          const_set(:INTERNAL_CLAMP, true)
          const_set(:SERVER_KEY, server_key)
          const_set(:RAW_NAME, raw)
          define_singleton_method(:name) { "Rho::Mcp::Tools[#{public_name}]" }
          define_singleton_method(:inspect) { name }
          define_method(:initialize) { |env:| @env = env }
          define_method(:call) { |args| caller.call(server_key, raw, args, env: @env, public_name: public_name) }
        end
      end
    end
  end
end
