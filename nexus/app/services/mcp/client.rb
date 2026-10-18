module Mcp
  class Client
    PROTOCOL_VERSIONS = %w[2026-07-28 2025-11-25].freeze
    MAX_PAGES = 16
    MAX_CURSOR_BYTES = 4096
    DEFAULT_TIMEOUT_SECONDS = 30

    def self.open(endpoint_url:, bearer_token: nil, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, cancelled: -> { false })
      client = new(endpoint_url: endpoint_url, bearer_token: bearer_token,
        timeout_seconds: timeout_seconds, cancelled: cancelled)
      client.connect
      yield client
    ensure
      client&.close
    end

    def initialize(endpoint_url:, bearer_token:, timeout_seconds:, cancelled:)
      @transport = HttpTransport.new(endpoint_url: endpoint_url, bearer_token: bearer_token,
        timeout_seconds: timeout_seconds, cancelled: cancelled)
      @protocol = MCP::Client.new(transport: @transport, input_required_max_rounds: 0, max_pages: MAX_PAGES)
    end

    def connect
      protocol_boundary do
        @protocol.connect(mode: :auto, protocol_version: "2025-11-25", capabilities: {},
          client_info: { name: "nexus", version: "1" })
        raise Error.new(:mcp_unsupported_protocol) unless PROTOCOL_VERSIONS.include?(@protocol.protocol_version)
      end
    end

    def list_tools
      protocol_boundary do
        tools = []
        seen_names = Set.new
        seen_cursors = Set.new
        cursor = nil
        # Each page advances the bounded page count; repeated cursors refuse the
        # entire directory, never publish a partial catalog as complete.
        MAX_PAGES.times do
          page = @protocol.list_tools(cursor: cursor)
          page.tools.each do |tool|
            entry = catalog_entry(tool)
            raise Error.new(:mcp_invalid_catalog) unless seen_names.add?(entry.fetch("name"))

            tools << entry
          end
          raise Error.new(:mcp_catalog_too_large) unless Nexus::SizeBounds.json_within?(:tool_definitions_bound, tools)

          return tools if page.next_cursor.nil?

          cursor = page.next_cursor.to_s
          unless cursor.present? && cursor.bytesize <= MAX_CURSOR_BYTES && seen_cursors.add?(cursor)
            raise Error.new(:mcp_invalid_catalog)
          end
        end
        raise Error.new(:mcp_catalog_too_large)
      end
    end

    def call_tool(name:, arguments:)
      protocol_boundary do
        result = @protocol.call_tool(name: name, arguments: arguments).fetch("result")
        if result.key?("resultType") && result["resultType"] != "complete"
          raise Error.new(:mcp_unsupported_result, request_sent: @transport.tool_request_sent)
        end
        result
      end
    end

    def close = @transport.close

    private

      def protocol_boundary
        yield
      rescue MCP::Client::InputRequiredError
        raise Error.new(:mcp_input_required, request_sent: @transport.tool_request_sent), cause: nil
      rescue MCP::Client::ServerError, MCP::Client::RequestHandlerError, MCP::Client::ValidationError,
          Nexus::CanonicalJson::UnsupportedValue
        raise Error.new(:mcp_protocol_error, request_sent: @transport.tool_request_sent), cause: nil
      end

      def catalog_entry(tool)
        name = tool.name.to_s
        schema = Hash.try_convert(tool.input_schema)
        unless name.present? && name.length <= 128 && !name.include?("\u0000") && schema&.fetch("type", nil) == "object"
          raise Error.new(:mcp_invalid_catalog)
        end
        entry = { "name" => name, "description" => tool.description.to_s, "input_schema" => schema }
        if tool.output_schema
          output = Hash.try_convert(tool.output_schema)
          raise Error.new(:mcp_invalid_catalog) unless output&.fetch("type", nil) == "object"

          entry["output_schema"] = output
        end
        if tool.annotations
          annotations = Hash.try_convert(tool.annotations)
          raise Error.new(:mcp_invalid_catalog) unless annotations

          entry["annotations"] = annotations
        end
        entry
      end
  end
end
