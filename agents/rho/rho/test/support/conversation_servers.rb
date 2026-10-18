module RhoTest
  # THE REGISTRAR DOUBLE: an extension FILE with a static description — selected as an
  # operator's would be — registering the one conversation-servers block.
  # Its SET double answers the seam's four verbs: two curated classes per
  # entry (`mcp__<name>__lookup`, `mcp__<name>__paths`, each answering its
  # own name and query, and its row as `SERVER_KEY` — the seam's contract,
  # what the daemon's judgement keys a row on), a report row per entry
  # (`command: "down"` reports a down row), a digest over the names, and
  # `close`, which appends the anchor to `closes` so a test reads what was
  # closed and when. A malformed entry — no name — raises ArgumentError
  # with a sentence, the door's 400; `command: "stopping"` raises the
  # registrar's own `Rho::Runner::Error` (rho-mcp's `Closed` once its
  # shutdown ladder ran), the door's 503. No env value is ever read: a
  # secret handed in stays in the entry the daemon never logs.
  module ConversationServers
    def self.extension(dir, closes:)
      File.join(dir, "servers_extension.rb").tap do |path|
        File.write(path, <<~RUBY)
          module ConversationServersExtension
            NAME = "rho.servers"
            CLOSES = #{closes.inspect}
            PROFILE = { "kind" => "read_only", "destructive" => false, "effect_scope" => "open",
                        "idempotency" => "none", "reconciliation" => "none" }.freeze

            class Stopping < Rho::Runner::Error; end

            def self.tool_class(server, raw)
              public_name = "mcp__\#{server}__\#{raw}"
              Class.new do
                const_set(:NAME, public_name)
                const_set(:DESCRIPTION, "\#{raw} on \#{server}")
                const_set(:SCHEMA, { "type" => "object", "properties" => { "q" => { "type" => "string" } } })
                const_set(:EFFECT_PROFILE, PROFILE)
                const_set(:SERVER_KEY, server)
                define_method(:initialize) { |env:| @env = env }
                define_method(:call) { |args| Rho::Runner::Result.ok("\#{public_name}: \#{args["q"]}") }
              end
            end

            class Set
              attr_reader :classes, :report, :digest

              def initialize(anchor, entries)
                @anchor = anchor
                @classes = entries.flat_map do |entry|
                  %w[lookup paths].map { |raw| ConversationServersExtension.tool_class(entry.fetch("name"), raw) }
                end
                @report = entries.map do |entry|
                  down = entry["command"] == "down"
                  { name: entry.fetch("name"), state: down ? "down" : "connected", fault: (down ? "exit 1" : nil),
                    transport: entry["type"] || "stdio" }
                end
                @digest = entries.map { |entry| entry.fetch("name") }.join(",")
              end

              def close
                File.write(CLOSES, "\#{@anchor}\\n", mode: "a")
              end
            end

            def self.register(api)
              api.register_conversation_servers do |anchor, entries|
                entries.each do |entry|
                  raise ArgumentError, "a server entry needs a name" unless entry["name"].is_a?(String) && !entry["name"].empty?
                end
                raise Stopping, "the mcp host is shutting down" if entries.any? { |entry| entry["command"] == "stopping" }

                Set.new(anchor, entries)
              end
            end
          end
        RUBY
      end.then { |path| RhoTest.described_extension(path, id: "rho.servers") }
    end

    # The ACP `mcpServers` shapes as the door receives them.
    def self.stdio(name, command: "fx-server", env: [{ "name" => "FX_TOKEN", "value" => "hunter2" }])
      { "name" => name, "command" => command, "args" => ["--stdio"], "env" => env }
    end

    def self.http(name, url: "http://127.0.0.1:9/mcp")
      { "type" => "http", "name" => name, "url" => url, "headers" => [{ "name" => "Authorization", "value" => "Bearer hunter2" }] }
    end
  end
end
