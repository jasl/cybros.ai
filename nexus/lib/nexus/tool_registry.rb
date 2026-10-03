require_relative "skills"

module Nexus
  # The kernel's tool registry. Canonical names are source.category.name where
  # the source executes it (`nexus.*` here, `rho.*` in the agent); the wire name
  # is stored, never computed, because it may already sit on a cached prefix.
  module ToolRegistry
    SOURCE = "nexus".freeze
    CANONICAL_NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*){1,2}\z/

    # The closed effect vocabulary: trusted metadata for recovery classification,
    # restricted-context admission and approval routing — never a security
    # boundary and never on the provider wire.
    EFFECT_KEYS = %w[kind destructive world idempotency reconciliation].freeze
    EFFECT_KINDS = %w[pure read_only write].freeze
    EFFECT_WORLDS = %w[closed open].freeze
    IDEMPOTENCY_KINDS = %w[intrinsic keyed none].freeze
    RECONCILIATION_KINDS = %w[none lookup].freeze
    # The effects a re-run cannot escape from (the predecessor's "pure and
    # read_only effects are replayable"): these kinds, or any kind whose
    # idempotency is intrinsic.
    REPLAYABLE_KINDS = %w[pure read_only].freeze

    READ_ONLY_CLOSED = {
      "kind" => "read_only", "destructive" => false, "world" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "none",
    }.freeze
    # A composed subgraph is written once and RECOVERED by looking up its
    # own keys — the script is pure, so a re-run rebuilds them exactly.
    GRAPH_WRITE = {
      "kind" => "write", "destructive" => false, "world" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "lookup",
    }.freeze

    # Memory reads touch nothing and re-read the same bytes.
    MEMORY_READ = READ_ONLY_CLOSED
    # A whole-document replace is intrinsically idempotent, so no idempotency
    # key or version history; `destructive` because the previous content is gone.
    MEMORY_WRITE = {
      "kind" => "write", "destructive" => true, "world" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "lookup",
    }.freeze
    # An edit is a find-and-replace, so a RETRY finds its own `old_text`
    # already gone. That is a property of the verb rather than of the
    # store, and it is the one memory verb that is not intrinsic.
    MEMORY_EDIT = MEMORY_WRITE.merge("idempotency" => "none").freeze

    # A TOOL-NAME MACRO in a description or a parameter description: a kernel
    # wire name in double braces, `{{task}}`, wherever the text names a
    # kernel tool AS THE TOOL. A profile that declares its own spelling of a
    # kernel tool (an alias on its declaration, `Nexus::ToolDeclarations`)
    # has every macro rendered with its names at declaration; everywhere else
    # — the catalog, the plain declaration — the render is PLAIN: the braces
    # gone, the kernel's own wire name, the bytes of before. A runner's tool
    # name is never a macro — it has no alias mechanism — and no kernel text
    # names one: a runner describes its own tools in its own prose. The
    # grammar's `g.ask`, the `<task_result>` and `<message>` envelopes and
    # their attributes are not tools.
    MACRO = /\{\{([a-z][a-z0-9_]*)\}\}/

    # The one substitution: every macro to its spelling, an unmapped one to itself.
    def self.render_text(template, spellings = {})
      template.to_s.gsub(MACRO) { spellings.fetch(Regexp.last_match(1), Regexp.last_match(1)) }
    end

    # A parameter schema with every property description rendered; the
    # rest of the schema is shared, not copied.
    def self.render_schema(schema, spellings = {})
      properties = Hash.try_convert(schema["properties"]) or return schema
      rendered = properties.transform_values do |property|
        next property unless property.is_a?(Hash) && property.key?("description")

        property.merge("description" => render_text(property["description"], spellings))
      end
      schema.merge("properties" => rendered)
    end

    # One registered tool. `template` and `parameter_template` are the
    # source texts with their macros; `description` and `parameters` are
    # the plain render, computed once here. The provider-facing schema is
    # exactly name/description/parameters; effect_profile, executor and job
    # never reach the wire. `executor` names the kernel service that answers
    # the call (`call(node:)`), `job` the process it runs in when the row
    # runs in-process (`AgentLoops::Dispatch`) — both by name, since this
    # file loads outside Rails.
    Tool = Data.define(:canonical, :name, :template, :description, :parameter_template, :parameters,
      :effect_profile, :executor, :job) do
      def initialize(canonical:, name:, template:, parameters:, effect_profile:, executor:, job:)
        raise ArgumentError, "#{canonical}: not a canonical tool name" unless CANONICAL_NAME_FORMAT.match?(canonical)

        super(canonical: canonical, name: name, template: template,
          description: ToolRegistry.render_text(template),
          parameter_template: parameters, parameters: ToolRegistry.render_schema(parameters),
          effect_profile: effect_profile, executor: executor, job: job)
      end

      def wire_schema = { "name" => name, "description" => description, "parameters" => parameters }

      def function_definition = { "type" => "function", "function" => wire_schema }.freeze

      # The kernel parameters an alias may map, omit or must not shadow.
      def parameter_names = (Hash.try_convert(parameter_template["properties"]) || {}).keys
    end

    # The four slices of the live table, each its own file; the registry's
    # `Tool` and effect constants above must exist before they load, and
    # they load here so this file still stands alone outside Rails.
    require_relative "tool_registry/graph"
    require_relative "tool_registry/conversation"
    require_relative "tool_registry/memory"
    require_relative "tool_registry/skill"
    require_relative "tool_registry/history"

    LIVE = [*Graph::TOOLS, *Conversation::TOOLS, *Memory::TOOLS, *Skill::TOOLS, *History::TOOLS]
      .index_by(&:canonical).freeze

    # Namespaces no external party can implement — they write kernel rows
    # (graph authoring, the human ask, the inbox/task verbs) — so no
    # provider may override a tool in them. Everything LIVE outside them
    # and outside ROUTED_BY_SOURCE (today exactly nexus.memory.*) is
    # overridable through the announcement door and, once a workspace
    # opts in (`Workspace#tool_provider_overrides`), routed to the
    # provider.
    RESERVED_NAMESPACES = %w[nexus.graph nexus.human nexus.conversation].freeze

    # THE ONE CLASSIFIER of the third class: a namespace whose tool is
    # routed PER CALL by its argument's source — `skill {name}` goes to the
    # executor that announced `name` under `documents`, else runs in-process
    # (`AgentLoops::Skills::Dispatch`). Announceable (the door admits the
    # wire name, so the announcer can serve the row) and NEVER overridable
    # (no workspace map names it: the route is per call, not per namespace).
    # `overridable?`, `overridable_namespaces` and the announcement door's
    # admission all derive from this list.
    ROUTED_BY_SOURCE = %w[nexus.skill].freeze

    # wire name => canonical: whatever a live tool declared — a shipped name
    # is bytes on a cached prefix.
    WIRE_ALIASES = LIVE.to_h { |canonical, tool| [tool.name, canonical] }.freeze

    class << self
      # Canonical name or wire alias in; canonical name or nil out. The
      # precise spelling always works; the wire spelling works while it is
      # unambiguous.
      def resolve(name)
        name = name.to_s
        return name if LIVE.key?(name)

        WIRE_ALIASES[name]
      end

      # The kernel's name space in both spellings, which is also exactly what
      # the kernel executes: every LIVE entry carries its executor. What the
      # client append door refuses, what a runner may never claim under a
      # reserved namespace, and what a workspace may route to a provider.
      def kernel_name?(name) = resolve(name).present?

      # The first two segments of a canonical id: the source and the family.
      def namespace(canonical) = canonical.to_s.split(".").first(2).join(".")

      def reserved_namespace?(canonical) = RESERVED_NAMESPACES.include?(namespace(canonical))

      # A live kernel tool whose call is addressed by its argument's
      # announcer (ROUTED_BY_SOURCE): the third class, beside reserved and
      # overridable — every live name is exactly one of the three.
      def routed_by_source?(canonical) = ROUTED_BY_SOURCE.include?(namespace(canonical))

      # A live kernel tool a provider may serve in the kernel's place:
      # LIVE, outside every reserved namespace and not routed by source.
      def overridable?(name)
        kernel_name?(name) && !reserved_namespace?(resolve(name)) && !routed_by_source?(resolve(name))
      end

      # The namespaces a workspace may opt into a provider: LIVE minus the
      # reserved set and the source-routed one — today exactly
      # `nexus.memory`. A future overridable family joins by this list alone.
      def overridable_namespaces
        LIVE.keys.map { |canonical| namespace(canonical) }.uniq - RESERVED_NAMESPACES - ROUTED_BY_SOURCE
      end

      # The wire names a provider must announce to serve a namespace WHOLE
      # (the completeness rule, names only): a provider taking `memory_read`
      # while the kernel keeps `memory_write` would be two memories under one family.
      def wire_names_in(namespace)
        LIVE.values.select { |tool| self.namespace(tool.canonical) == namespace }.map(&:name)
      end

      def entry(name) = LIVE[resolve(name).to_s]

      def executor_for(name) = entry(name)&.executor&.constantize

      # The process a kernel-run row is handed to after its scheduling
      # transaction commits (`AgentLoops::Dispatch`).
      def job_for(name) = entry(name).job.constantize

      def wire_schema_for(name) = entry(name).wire_schema

      def effect_profile_for(name) = entry(name).effect_profile

      # The vocabulary's one reading of a profile document: replayable iff
      # its kind is read-only/pure or its idempotency intrinsic. An absent
      # or malformed profile is NOT replayable (unknown = write-capable).
      def replayable?(profile)
        profile = Hash.try_convert(profile)
        return false if profile.nil?

        REPLAYABLE_KINDS.include?(profile["kind"]) || profile["idempotency"] == "intrinsic"
      end

      def function_definition(name) = entry(name).function_definition

      def live_names = LIVE.keys
    end
  end
end
