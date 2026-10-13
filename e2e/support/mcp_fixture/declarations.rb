module E2E
  # THE FIXTURE SERVER'S DECLARATIONS, shared by the server that lists them and the journey that
  # pins them VERBATIM on discovery and on the wire. One canonical Hash per tool in the shape the
  # gem's server LISTS it — `$schema` first (the gem's own `Schema#to_h` prepends it), then `type`,
  # `properties`, `required` in the order given — so the bytes the journey lowers are the bytes rho
  # announced. Nothing here is shaped by rho: a description is the server's own text, byte for byte.
  module McpFixture
    JSON_SCHEMA = "https://json-schema.org/draft/2020-12/schema".freeze
    SERVER_NAME = "fx-server".freeze
    SERVER_VERSION = "1.0.0".freeze
    ECHO_TEXT_PREFIX = "fx echoes: ".freeze
    LOOKUP_RECORD = { "key" => nil, "record" => "the fx record", "hits" => 2 }.freeze
    HANG_SECONDS = 20
    EXIT_STATUS = 3

    def self.schema(properties, required = nil)
      base = { "$schema" => JSON_SCHEMA, "type" => "object", "properties" => properties }
      required ? base.merge("required" => required) : base
    end

    TOOLS = [
      { "name" => "echo", "description" => "Echo the text back, prefixed by the server's own word.",
        "inputSchema" => schema({ "text" => { "type" => "string", "description" => "What to echo." } }, ["text"]) },
      { "name" => "lookup", "description" => "Look a key up and answer its record, with the record as structured content.",
        "inputSchema" => schema({ "key" => { "type" => "string" }, "file.path" => { "type" => "string" } }, ["key"]) },
      { "name" => "paths", "description" => "Answer how many paths were given.",
        "inputSchema" => schema({ "paths" => { "type" => "array", "items" => { "type" => "string" } } }, ["paths"]) },
      { "name" => "hang", "description" => "Sleep for twenty seconds before answering.",
        "inputSchema" => schema({}) },
      { "name" => "exit", "description" => "Exit with status 3 in the middle of the request.",
        "inputSchema" => schema({}) },
      { "name" => "write", "description" => "Write a note somewhere.",
        "inputSchema" => schema({ "text" => { "type" => "string" } }) },
      { "name" => "env", "description" => "List the names of the server process's environment variables.",
        "inputSchema" => schema({}) },
    ].freeze

    ALLOWLIST = %w[echo lookup paths hang exit].freeze

    # THE DOCUMENTS: prompts `summarize` (no arguments, described) and `greet` (a required argument
    # — never announced); resources `readme` (`text/markdown`), `notes` (NO listing mimeType, `text`
    # contents — announced, the read decides), `blob` (`application/octet-stream` — never
    # announced); one resource template (the probe's list, never a document). The bodies are what
    # the `skill` rows answer, byte for byte.
    SUMMARIZE_DESCRIPTION = "Summarize the notes the room has gathered so far.".freeze
    SUMMARIZE_TEXT = "Summarize the notes in three bullets.\nName the open questions last.".freeze
    GREET_DESCRIPTION = "Greet somebody by name.".freeze
    README_DESCRIPTION = "The fixture project's readme.".freeze
    README_TEXT = "# fx\n\nA fixture server for rho's e2e journeys.\n".freeze
    NOTES_DESCRIPTION = "The room's notes, typed by nobody.".freeze
    NOTES_TEXT = "note one\nnote two\n".freeze
    BLOB_DESCRIPTION = "An opaque blob nobody can read.".freeze

    # The announced document entries as rho announces them on a server's row.
    def self.documents(server_key)
      { "summarize" => SUMMARIZE_DESCRIPTION, "readme" => README_DESCRIPTION, "notes" => NOTES_DESCRIPTION }
        .map { |name, description| { "name" => "#{server_key}-#{name}", "description" => description } }
    end

    # The declarations as rho announces them: the public name, the same bytes.
    def self.announced(server_key, names = ALLOWLIST)
      TOOLS.select { |tool| names.include?(tool.fetch("name")) }
        .map { |tool| tool.merge("name" => "mcp__#{server_key}__#{tool.fetch("name")}") }
    end
  end
end
