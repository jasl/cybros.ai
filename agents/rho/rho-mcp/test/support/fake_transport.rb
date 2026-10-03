require "json"
require "mcp"

module McpTest
  # AN IN-PROCESS `MCP::Server` BEHIND THE SDK'S DUCK TRANSPORT: answers
  # `send_request` by handing the JSON-RPC frame to the server, `connect`
  # by the legacy `initialize` through it, `send_notification` by
  # recording the frame — no process. What a real child would do is
  # simulated on demand: `die!` marks the server exited (a request in
  # flight then raises the SDK's own "closed stdout" error, a later one
  # "has exited"), `hold!` makes a named tool block until the transport is
  # closed or the server dies (the poison rule's fixture), `close` counts.
  class FakeTransport
    attr_reader :server, :closes, :notifications, :requests, :read_timeout, :exit_status, :exited_at, :starts,
      :read_timeouts_seen
    attr_accessor :stderr_tail, :pid, :group_pid, :spawn_error

    def initialize(server, held: [], input_required: [])
      @server = server
      @held = held
      @input_required = input_required
      @closes = 0
      @starts = 0
      @notifications = []
      @requests = []
      @server_info = nil
      @connected = false
      @exit_status = nil
      @exited_at = nil
      @stderr_tail = +""
      @pid = 4242
      @group_pid = 4241
      @wake = Queue.new
      @lock = Mutex.new
      @spawn_error = nil
      @read_timeouts_seen = []
    end

    def read_timeout=(value)
      @read_timeout = value
    end

    def connect(client_info:, protocol_version: nil, capabilities: {}, mode: :legacy)
      raise MCP::Client::RequestHandlerError.new(@spawn_error, {}, error_type: :internal_error) if @spawn_error

      @starts += 1
      @read_timeouts_seen << @read_timeout
      client_info ||= { name: "test", version: "0" }
      request = { jsonrpc: "2.0", id: "init", method: "initialize",
                  params: { protocolVersion: protocol_version || MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION,
                            capabilities: capabilities, clientInfo: client_info } }
      response = handle(request)
      @server_info = response.fetch("result")
      handle({ jsonrpc: "2.0", method: "notifications/initialized" })
      @connected = true
      @server_info
    end

    def server_info = @server_info
    def protocol_version = @server_info&.dig("protocolVersion")
    def connected? = @connected
    def modern? = false
    def exited? = !@exit_status.nil?
    def exit_description = exited? ? "status #{@exit_status}" : "status unknown"

    def send_request(request:)
      raise dead_error("Server process has exited") if exited?

      @requests << request
      yield if block_given?
      hold if held?(request)
      return input_required_frame(request) if asks_for_input?(request)

      response = handle(request)
      raise dead_error("Server process closed stdout unexpectedly") if exited?

      response
    end

    def send_notification(notification:)
      @notifications << notification
      nil
    end

    def close
      @closes += 1
      @connected = false
      @server_info = nil
      @wake << :closed
      nil
    end

    # The poison rule's KILL counts as a close: the fake has no group.
    def kill = close

    # The watcher and the drain a real transport settles under the bound:
    # the fake's exit is recorded the moment `die!` runs, so it answers at once.
    def settle(_seconds) = exited?

    # The server leaves: status recorded as the watcher would, a request
    # in flight woken to read the closed pipe.
    # `exited_at` stays nil: the connection falls to its own clock, so a
    # test's fake clock stamps the record.
    def die!(status: 3, tail: nil)
      @exit_status = status
      @stderr_tail = tail if tail
      @wake << :died
      nil
    end

    private

      def held?(request)
        request[:method] == "tools/call" && @held.include?(request.dig(:params, :name))
      end

      # SEP-2322 on the wire, as a 2026 server answers it: a `prompts/get`
      # of a named prompt is an `input_required` result the client — with
      # no handler — raises as `InputRequiredError` (the gem's legacy
      # server cannot produce one over this duck transport).
      def asks_for_input?(request)
        request[:method] == "prompts/get" && @input_required.include?(request.dig(:params, :name))
      end

      def input_required_frame(request)
        { "jsonrpc" => "2.0", "id" => request[:id],
          "result" => { "resultType" => "input_required", "requestState" => "s1",
                        "inputRequests" => { "q1" => { "method" => "elicitation/create", "params" => { "message" => "who?" } } } } }
      end

      def hold
        @wake.pop
      end

      def handle(request)
        answer = @server.handle_json(JSON.generate(request))
        answer.nil? ? nil : JSON.parse(answer)
      end

      def dead_error(message)
        MCP::Client::RequestHandlerError.new(message, {}, error_type: :internal_error)
      end
  end

  # The fixture server's declarations, the same in-process and spawned.
  module FixtureServer
    ECHO_DESCRIPTION = "Echo the text back, unchanged.".freeze
    LOOKUP_DESCRIPTION = "Look a key up and answer its record.".freeze

    SUMMARIZE_DESCRIPTION = "Summarize the notes in the room.".freeze
    README_DESCRIPTION = "The project's readme.".freeze
    DOCUMENTS = %w[summarize greet chatty asker readme notes blob logo nodesc template].freeze

    def self.build(tools: %w[echo lookup hang exit write picture noise refused blank env], name: "fx-server", version: "1.0.0",
                   hooks: {}, documents: [])
      server = MCP::Server.new(name: name, version: version, instructions: "Be kind to the operator.")
      tools.each { |tool| define(server, tool, hooks) }
      documents.each { |document| define_document(server, document) }
      server
    end

    def self.text(text) = MCP::Content::Text.new(text)

    def self.message(role, content) = MCP::Prompt::Message.new(role: role, content: content)

    # The prompts, resources and the one template the documents tests
    # list: the curated four (`summarize`, `chatty`, `readme`, `notes`,
    # `logo`), the skipped four (`greet`'s required argument, `blob`'s
    # octet-stream, `nodesc`'s missing description, the template).
    def self.define_document(server, document)
      case document
      when "summarize"
        server.define_prompt(name: "summarize", description: SUMMARIZE_DESCRIPTION) do |_args, server_context:|
          MCP::Prompt::Result.new(messages: [FixtureServer.message("user", FixtureServer.text("Summarize the notes.\nBe brief."))])
        end
      when "greet"
        server.define_prompt(name: "greet", description: "Greet somebody.",
          arguments: [MCP::Prompt::Argument.new(name: "who", required: true)]) do |args, server_context:|
          MCP::Prompt::Result.new(messages: [FixtureServer.message("user", FixtureServer.text("Hello #{args["who"]}"))])
        end
      when "chatty"
        server.define_prompt(name: "Chatty Prompt", description: "Two messages and a picture.",
          arguments: [MCP::Prompt::Argument.new(name: "tone", required: false)]) do |_args, server_context:|
          MCP::Prompt::Result.new(messages: [
            FixtureServer.message("user", FixtureServer.text("First line.")),
            FixtureServer.message("assistant", FixtureServer.text("An answer.")),
            FixtureServer.message("user", MCP::Content::Image.new(Base64.strict_encode64(McpTest::PNG), "image/png")),
          ])
        end
      when "asker"
        server.define_prompt(name: "asker", description: "Asks for input.") do |_args, server_context:|
          MCP::Prompt::Result.new(messages: [FixtureServer.message("user", FixtureServer.text("never"))])
        end
      when "readme"
        server.define_resource(uri: "fx://readme", name: "readme", description: README_DESCRIPTION, mime_type: "text/markdown") do
          [MCP::Resource::TextContents.new(text: "# Readme\n\nRead me.", uri: "fx://readme", mime_type: "text/markdown")]
        end
      when "notes"
        server.define_resource(uri: "fx://notes", name: "notes", description: "Notes with no listing type.") do
          [MCP::Resource::TextContents.new(text: "note one\nnote two", uri: "fx://notes", mime_type: "text/plain")]
        end
      when "blob"
        server.define_resource(uri: "fx://blob", name: "blob", description: "An opaque blob.", mime_type: "application/octet-stream") do
          [MCP::Resource::BlobContents.new(data: "AAAA", uri: "fx://blob", mime_type: "application/octet-stream")]
        end
      when "logo"
        server.define_resource(uri: "fx://logo", name: "logo", description: "The logo.", mime_type: "image/png") do
          [MCP::Resource::BlobContents.new(data: Base64.strict_encode64(McpTest::PNG), uri: "fx://logo", mime_type: "image/png")]
        end
      when "nodesc"
        server.define_resource(uri: "fx://nodesc", name: "nodesc") { [] }
      when "template"
        server.define_resource_template(uri_template: "fx://notes/{id}", name: "note", description: "One note by id.") { |id:| [] }
      else
        raise ArgumentError, "unknown fixture document #{document}"
      end
    end

    def self.define(server, tool, hooks = {})
      case tool
      when "echo"
        server.define_tool(name: "echo", description: ECHO_DESCRIPTION,
          input_schema: { properties: { text: { type: "string" } }, required: ["text"] }) do |text:|
          MCP::Tool::Response.new([{ type: "text", text: text }])
        end
      when "lookup"
        server.define_tool(name: "lookup", description: LOOKUP_DESCRIPTION,
          input_schema: { properties: { key: { type: "string" }, "file.path": { type: "string" } }, required: ["key"] }) do |key:, **|
          MCP::Tool::Response.new([{ type: "text", text: "record for #{key}" }], structured_content: { "key" => key, "hits" => 2 })
        end
      when "hang"
        server.define_tool(name: "hang", description: "Sleep for a while.",
          input_schema: { properties: {} }) { MCP::Tool::Response.new([{ type: "text", text: "slept" }]) }
      when "exit"
        server.define_tool(name: "exit", description: "Exit mid-request.",
          input_schema: { properties: {} }) do
          hooks["exit"]&.call
          MCP::Tool::Response.new([{ type: "text", text: "never" }])
        end
      when "write"
        server.define_tool(name: "write", description: "Write a note.",
          input_schema: { properties: { text: { type: "string" } } }) { MCP::Tool::Response.new([{ type: "text", text: "written" }]) }
      when "picture"
        server.define_tool(name: "picture", description: "Answer a picture and a sound.",
          input_schema: { properties: {} }) do
          MCP::Tool::Response.new([
            { type: "text", text: "here" },
            { type: "image", data: Base64.strict_encode64(McpTest::PNG), mimeType: "image/png" },
            { type: "audio", data: "AAAA", mimeType: "audio/wav" },
            { type: "resource_link", uri: "file:///etc/hosts", name: "hosts", mimeType: "text/plain" },
            { type: "resource", resource: { uri: "fx://note", mimeType: "text/plain", text: "embedded text" } },
            { type: "resource", resource: { uri: "fx://blob", mimeType: "application/octet-stream", blob: "AAAA" } },
            { type: "shape", data: "?" },
          ])
        end
      when "noise"
        server.define_tool(name: "noise", description: "Answer only structure.",
          input_schema: { properties: {} }) { MCP::Tool::Response.new([], structured_content: { "only" => "structure" }) }
      when "refused"
        server.define_tool(name: "refused", description: "Refuse, as a tool error.",
          input_schema: { properties: {} }) { MCP::Tool::Response.new([{ type: "text", text: "no such record" }], error: true) }
      when "blank"
        server.define_tool(name: "blank", description: nil, input_schema: { properties: {} }) { MCP::Tool::Response.new([]) }
      when "env"
        server.define_tool(name: "env", description: "List the environment's keys.",
          input_schema: { properties: {} }) { MCP::Tool::Response.new([{ type: "text", text: ENV.keys.sort.join("\n") }]) }
      when "dotted"
        server.define_tool(name: "dotted.name/with space", description: "A name the provider floor refuses.",
          input_schema: { properties: {} }) { MCP::Tool::Response.new([{ type: "text", text: "dotted" }]) }
      else
        raise ArgumentError, "unknown fixture tool #{tool}"
      end
    end
  end

  require "base64"
  # A 1×1 red PNG.
  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
  ).freeze
end
