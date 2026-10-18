require "json"
require "json_schemer"
require "securerandom"
require_relative "store_document"
require_relative "run_declaration"

module Rho
  # Authored configuration belongs to this profile Store document. A publication
  # adds selection metadata to the same Preset; neither operation creates a User.
  # Identity consumers retain only a public_id and resolve later executions anew.
  class AgentPresets
    class Error < ArgumentError; end

    NAMESPACE = "rho.presets".freeze
    KEY = "catalog".freeze
    MAX_PROMPT_BYTES = 64 * 1024

    Role = Data.define(:name, :description)
    Entry = Data.define(:public_id, :name, :description, :configuration, :role) do
      def to_h = super.merge(role: role&.to_h)
    end

    DEFAULT_CONFIGURATION = {
      "system_prompt" => nil, "model" => nil, "model_mode" => "default", "fallback_models" => nil,
      "tools" => nil, "runner_tool_names" => nil, "mcp" => { "disabled_connections" => [], "disabled_tools" => [] }, "prompt_template" => nil,
      "approval_mode" => nil, "approval_rules" => nil, "compaction_policy" => nil,
      "lifecycle_hooks" => nil, "memory_context_limit" => nil, "conversation_reach" => nil,
    }.freeze

    MODEL_SCHEMA = { "type" => "string", "maxLength" => 1024,
      "pattern" => '\A\s*[^\s/]+/[^\s]+\s*\z' }.freeze
    TOOL_NAMES_SCHEMA = { "type" => %w[array null], "items" => { "type" => "string" } }.freeze
    MCP_TOOL_NAME_SCHEMA = { "type" => "string", "minLength" => 1, "maxLength" => 128,
      "pattern" => '\\A[^\\x00]+\\z' }.freeze
    MCP_EXECUTOR_NAME_SCHEMA = { "type" => "string", "minLength" => 1 }.freeze
    MCP_UUID_SCHEMA = { "type" => "string", "maxLength" => 36,
      "pattern" => '\\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\z' }.freeze
    MCP_REFERENCES = [
      { "source" => { "const" => "nexus" }, "connection_public_id" => MCP_UUID_SCHEMA },
      { "source" => { "const" => "executor" }, "executor_public_id" => MCP_UUID_SCHEMA, "server_key" => MCP_EXECUTOR_NAME_SCHEMA },
    ].freeze
    MCP_SCHEMA = {
      "type" => "object", "required" => %w[disabled_connections disabled_tools], "additionalProperties" => false,
      "properties" => %w[disabled_connections disabled_tools].to_h do |field|
        schemas = MCP_REFERENCES.map do |reference|
          name_schema = reference.fetch("source").fetch("const") == "nexus" ? MCP_TOOL_NAME_SCHEMA : MCP_EXECUTOR_NAME_SCHEMA
          properties = field == "disabled_tools" ? reference.merge("tool_name" => name_schema) : reference
          { "type" => "object", "required" => properties.keys, "additionalProperties" => false, "properties" => properties }
        end
        [field, { "type" => "array", "uniqueItems" => true, "items" => { "oneOf" => schemas } }]
      end,
    }.freeze
    MEMORY_SCOPES = %w[conversation workspace user agent speaker].freeze
    MEMORY_LIMIT_SCHEMA = {
      "type" => %w[object null], "required" => ["bindings"], "additionalProperties" => false,
      "properties" => {
        "bindings" => { "type" => "array", "maxItems" => 16, "items" => {
          "type" => "object", "required" => %w[name scope access], "additionalProperties" => false,
          "properties" => {
            "name" => { "enum" => MEMORY_SCOPES }, "scope" => { "enum" => MEMORY_SCOPES },
            "access" => { "enum" => %w[read read_write] },
          },
        } },
      },
    }.freeze
    CONFIGURATION_SCHEMA = {
      "type" => "object", "additionalProperties" => false,
      "properties" => {
        "system_prompt" => { "type" => %w[string null] },
        "model" => { "anyOf" => [MODEL_SCHEMA, { "type" => "null" }] },
        "model_mode" => { "enum" => %w[follow default] },
        "fallback_models" => { "type" => %w[array null], "items" => MODEL_SCHEMA },
        "tools" => TOOL_NAMES_SCHEMA, "runner_tool_names" => TOOL_NAMES_SCHEMA, "mcp" => MCP_SCHEMA,
        "prompt_template" => { "type" => %w[object null] },
        "approval_mode" => { "enum" => [nil, "bypass", "ask", "rules"] },
        "approval_rules" => { "type" => %w[array null], "items" => { "type" => "object" } },
        "compaction_policy" => { "type" => %w[object null] },
        "lifecycle_hooks" => { "type" => %w[object null] },
        "memory_context_limit" => MEMORY_LIMIT_SCHEMA,
        "conversation_reach" => { "enum" => [nil, "workspace", "subtree"] },
      },
    }.freeze
    AUTHORED_SCHEMA = JSONSchemer.schema({
      "type" => "object", "additionalProperties" => false, "required" => %w[name description configuration],
      "properties" => {
        "name" => { "type" => "string", "minLength" => 1, "maxLength" => 128 },
        "description" => { "type" => "string", "minLength" => 1, "maxLength" => 1024 },
        "configuration" => CONFIGURATION_SCHEMA,
      },
    })
    ROLE_SCHEMA = JSONSchemer.schema({
      "type" => "object", "required" => %w[name description], "additionalProperties" => false,
      "properties" => {
        "name" => { "type" => "string", "pattern" => '\A[a-z0-9][a-z0-9_-]{1,31}\z' },
        "description" => { "type" => "string", "minLength" => 1, "maxLength" => 1024 },
      },
    })

    SEEDS = [
      { "name" => "Probius", "description" => "Work with the owner on coding, research and practical tasks.",
        "configuration" => { "system_prompt" => "Work with the user to complete their task. Inspect the relevant context, " \
          "make concrete changes when requested, and verify the result. Delegate bounded work to suitable roles with an explicit " \
          "task and the context they need. Report outcomes, evidence and remaining limits clearly." } },
      { "name" => "Adjutant", "description" => "Help people through a connected chat and coordinate delegated work.",
        "configuration" => { "system_prompt" => "Help the person in this chat with concise, useful replies. Complete authorized " \
          "tasks through the available tools and delegate substantial work with a clear brief. Keep updates readable on a messaging " \
          "channel. Respect this Bot's audience, available tools and conversation boundaries." } },
      { "name" => "worker", "description" => "Carry out a bounded task or an implementation plan.",
        "configuration" => { "model_mode" => "follow", "system_prompt" => "Complete the supplied task or plan. Use the explicit " \
          "brief and available evidence; inspect what is needed, implement the requested changes and verify them. Keep work within " \
          "the assigned scope. Report the result, changed artifacts, verification and any unresolved blocker to the delegator." },
        "role" => { "name" => "worker", "description" => "Choose for ordinary implementation or execution of a supplied task or plan." } },
      { "name" => "planner", "description" => "Turn a goal and constraints into a concrete, verifiable plan.",
        "configuration" => { "model_mode" => "follow", "runner_tool_names" => %w[read grep ls find web_fetch],
          "system_prompt" => "Investigate the supplied goal, current implementation and constraints. Identify decisions that " \
            "affect correctness and propose the smallest coherent sequence of work with verification criteria. Cite the evidence " \
            "behind assumptions. Return a plan; do not implement changes unless the task explicitly requests them." },
        "role" => { "name" => "planner", "description" => "Choose when requirements, dependencies or implementation order need investigation before execution." } },
      { "name" => "explorer", "description" => "Inspect a codebase, documents or environment and report grounded findings.",
        "configuration" => { "model_mode" => "follow", "runner_tool_names" => %w[read grep ls find web_fetch],
          "system_prompt" => "Investigate the question in the supplied brief using read-only inspection. Trace ownership and " \
            "data flow, locate relevant code or documents, and report concrete evidence with source locations. Separate verified " \
            "facts from uncertainty. Do not modify the material being inspected." },
        "role" => { "name" => "explorer", "description" => "Choose for focused code, document or environment investigation and evidence gathering." } },
      { "name" => "reviewer", "description" => "Assess supplied work for concrete defects and missing verification.",
        "configuration" => { "model_mode" => "follow", "runner_tool_names" => %w[read grep ls find bash web_fetch],
          "system_prompt" => "Review the supplied change or result against its requirements and surrounding behavior. Investigate " \
            "specific failure paths and run relevant checks when useful. Report actionable findings with evidence, consequence " \
            "and location; distinguish defects from preferences. Do not change the reviewed work unless explicitly assigned a fix." },
        "role" => { "name" => "reviewer", "description" => "Choose to review a completed change or result for defects, regressions and gaps in verification." } },
    ].freeze

    def initialize(store:)
      @document = StoreDocument.new(store: store, namespace: NAMESPACE, key: KEY)
    end

    def list = document.fetch("presets").map { |row| entry(row) }

    def fetch(public_id) = entry(find(document, public_id.to_s))

    def create(name:, description:, configuration: {})
      insert(authored(name: name, description: description, configuration: configuration))
    end

    # Replacement changes authored configuration, never the selected identity,
    # existing role publication or any already-returned execution value.
    def replace(public_id, name:, description:, configuration:)
      fields = authored(name: name, description: description, configuration: configuration)
      change_entry(public_id) { |row, _catalog| row.merge!(fields) }
    end

    def duplicate(public_id, name:)
      original = find(document, public_id.to_s)
      fields = { "name" => String.try_convert(name)&.strip, "description" => original.fetch("description"),
        "configuration" => original.fetch("configuration") }
      validate(AUTHORED_SCHEMA, fields)
      insert(fields)
    end

    def remove(public_id)
      id = public_id.to_s
      removed = nil
      change do |catalog|
        removed = find(catalog, id)
        if catalog.fetch("main_preset_public_id") == id
          raise Error, "Preset is in use by main Agent"
        elsif catalog.fetch("default_bot_preset_public_id") == id
          raise Error, "Preset is in use as the default Bot Preset"
        end
        catalog.fetch("presets").delete(removed)
      end
      entry(removed)
    end

    def publish(public_id, name:, description:)
      role = { "name" => String.try_convert(name)&.strip&.downcase, "description" => String.try_convert(description)&.split&.join(" ") }
      validate(ROLE_SCHEMA, role)
      change_entry(public_id) do |row, catalog|
        if catalog.fetch("presets").any? { |other| other.fetch("public_id") != row.fetch("public_id") && other.dig("role", "name") == role.fetch("name") }
          raise Error, "Subagent role name is already published: #{role.fetch("name")}"
        end
        row["role"] = role
      end
    end

    def unpublish(public_id)
      change_entry(public_id) { |row, _catalog| row["role"] = nil }
    end

    def main_preset_public_id = document.fetch("main_preset_public_id")

    def default_bot_preset_public_id = document.fetch("default_bot_preset_public_id")

    def select_main(public_id) = select(public_id, "main_preset_public_id")

    def select_default_bot(public_id) = select(public_id, "default_bot_preset_public_id")

    def select_defaults(fields)
      change do |catalog|
        fields.each_value { |id| find(catalog, id.to_s) }
        fields.each { |key, id| catalog[key] = id.to_s }
      end
      nil
    end

    private

      # The catalog's existence is the initialization fact, independent of its
      # entries. Reopening never restores deleted or renamed built-in Presets.
      def document
        @document.read || @document.change do |catalog|
          if catalog.empty?
            rows = SEEDS.map do |seed|
              seed.merge("public_id" => SecureRandom.uuid_v7, "role" => seed["role"],
                "configuration" => DEFAULT_CONFIGURATION.merge(seed.fetch("configuration")))
            end
            catalog.replace("presets" => rows,
              "main_preset_public_id" => rows[0].fetch("public_id"),
              "default_bot_preset_public_id" => rows[1].fetch("public_id"))
          end
        end
      rescue CybrosAgent::Api::Conflict => error
        # Concurrent initial readers may generate different seed UUIDs. The
        # committed catalog wins; authored edits still use ordinary CAS failure.
        raise unless error.code == "key_taken"

        @document.read || raise
      end

      def entry(row)
        role = row.fetch("role")
        Entry.new(public_id: row.fetch("public_id"), name: row.fetch("name"), description: row.fetch("description"),
          configuration: row.fetch("configuration"), role: role && Role.new(**role.transform_keys(&:to_sym)))
      end

      def find(catalog, public_id)
        catalog.fetch("presets").find { |row| row.fetch("public_id") == public_id } ||
          raise(Error, "No Preset with public id #{public_id}")
      end

      # JSON detaches caller-owned nested values at this one authoring boundary.
      # Kernel-specific policy grammar is still validated by its owning compiler.
      def authored(name:, description:, configuration:)
        configuration = Hash.try_convert(configuration)
        raise Error, "Preset configuration must be an object" if configuration.nil?

        values = DEFAULT_CONFIGURATION.merge(JSON.parse(JSON.generate(configuration)))
        fields = { "name" => String.try_convert(name)&.strip, "description" => String.try_convert(description)&.strip, "configuration" => values }
        validate(AUTHORED_SCHEMA, fields)
        validate_memory_limit(values.fetch("memory_context_limit"))
        normalize_mcp(values.fetch("mcp"))
        prompt = [RunDeclaration::GUIDELINE, values.fetch("system_prompt")].compact.reject(&:empty?).join("\n\n")
        if prompt.encode(Encoding::UTF_8).bytesize > MAX_PROMPT_BYTES
          raise Error, "Preset prompt and shared guidance must compose to at most 64 KiB of UTF-8 text"
        end
        values["model"] = values.fetch("model")&.strip
        %w[fallback_models tools runner_tool_names].each do |key|
          selected = values.fetch(key)
          values[key] = selected&.map(&:strip)&.reject(&:empty?)&.uniq
        end
        fields
      end

      def validate(schema, value)
        error = schema.validate(value).first
        if error
          raise Error, "Invalid Preset field #{error.fetch("data_pointer")}: #{error.fetch("type")}"
        end
      end

      def validate_memory_limit(limit)
        return if limit.nil?

        bindings = limit.fetch("bindings")
        names = bindings.map { |binding| binding.fetch("name") }
        unless bindings.all? { |binding| binding.fetch("name") == binding.fetch("scope") } &&
            names.uniq.length == names.length && (names.empty? || names.include?("conversation"))
          raise Error, "Invalid Preset field /configuration/memory_context_limit: use unique natural roots including conversation"
        end
      end

      # Connection identity is the selection boundary. Missing/offline entries
      # remain authored so a reconnect does not silently turn them back on.
      def normalize_mcp(selection)
        selection.each_value do |entries|
          entries.each do |entry|
            %w[connection_public_id executor_public_id].each do |key|
              entry[key] = entry.fetch(key).downcase if entry.key?(key)
            end
          end
          entries.uniq!
        end
      end

      def insert(fields)
        id = SecureRandom.uuid_v7
        saved = change { |catalog| catalog.fetch("presets") << fields.merge("public_id" => id, "role" => nil) }
        entry(find(saved, id))
      end

      def change_entry(public_id)
        id = public_id.to_s
        saved = change do |catalog|
          row = find(catalog, id)
          yield row, catalog
        end
        entry(find(saved, id))
      end

      def change(&block)
        document
        @document.change(&block)
      end

      def select(public_id, key)
        id = public_id.to_s
        saved = change do |catalog|
          find(catalog, id)
          catalog[key] = id
        end
        entry(find(saved, id))
      end
  end
end
