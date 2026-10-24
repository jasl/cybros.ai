require_relative "echo_tools"
require_relative "guarded_tools"

module E2E
  # Scope-keyed provider fixture for routing, override removal and access tests.
  # Only read/write/ls are exercised. The family announcement includes all six
  # verbs; unused handlers fail explicitly instead of simulating the kernel.
  module MemoryTools
    NAME = "e2e.memory".freeze

    # The kernel's own profiles, mirrored (`Nexus::ToolRegistry`): reads
    # are the closed read-only profile the echo tools share; a whole
    # document replace is intrinsically idempotent and destructive; an
    # edit is the one memory verb whose retry cannot find its own
    # `old_text` again.
    MEMORY_WRITE = {
      "kind" => "write", "destructive" => true, "effect_scope" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "lookup",
    }.freeze
    MEMORY_EDIT = MEMORY_WRITE.merge("idempotency" => "none").freeze
    # The echo tools' park, declared on every verb class as its own.
    TIMEOUT_MS = EchoTools::TIMEOUT_MS
    PATH_PROPERTY = { "type" => "string", "description" => "Scoped path, e.g. workspace/notes.md" }.freeze

    Binding = Data.define(:name, :scope, :access, :public_id) do
      def self.from_h(value)
        scope = value.fetch("scope")
        anchor = scope == "speaker" ? [value.fetch("agent_public_id"), value.fetch("speaker_public_id")] : value.fetch("#{scope}_public_id")
        new(name: value.fetch("name"), scope: scope, access: value.fetch("access"), public_id: anchor)
      end

      def key = [scope, public_id]
    end

    # The real executor runs handlers concurrently; the fixture shares one store.
    module Store
      MUTEX = Mutex.new
      @documents = {}

      module_function

      def read(key) = MUTEX.synchronize { @documents[key] }
      def write(key, content) = MUTEX.synchronize { @documents[key] = content }
      def clear! = MUTEX.synchronize { @documents.clear }

      def paths(bindings, prefix)
        MUTEX.synchronize do
          @documents.keys.flat_map do |scope, scope_id, name|
            bindings.filter_map do |binding|
              path = "#{binding.name}/#{name}"
              path if binding.key == [scope, scope_id] && path.start_with?(prefix)
            end
          end.sort
        end
      end
    end

    # The handler every memory verb shares: cancellation honoured at the
    # one checkpoint, the row's stamp read off the bound context, a path
    # resolved to `[scope, scope_id, name]` the way `Scopes::Anchor` does,
    # and the kernel's refusal form (`code: detail`, is_error).
    class Verb
      def initialize(env:); end

      def call(args)
        Rho::Env::ExecutionContext.current&.raise_if_cancelled!
        scope = Rho::Env::ExecutionContext.current&.scope
        return refuse(:memory_scope_unavailable, "no scope on the row") if scope.nil?

        run(args, scope.fetch("bindings").map { |entry| Binding.from_h(entry) })
      end

      private

        def refuse(code, detail = nil) = Rho::Env::Result.error([code, detail].compact.join(": "))

        def ok(text) = Rho::Env::Result.ok(text)

        # The bare name is refused rather than defaulted, and a scope whose
        # id the stamp lacks (a standalone row's conversation) is refused
        # as data — the kernel's two answers.
        def anchor(path, bindings, authoring: false)
          scope_name, name = path.to_s.split("/", 2)
          return [nil, :memory_path_invalid] if name.to_s.empty?

          binding = bindings.find { |entry| entry.name == scope_name }
          return [nil, :memory_scope_unavailable] if binding.nil?
          return [nil, :memory_read_only] if authoring && binding.access != "read_write"

          [[*binding.key, name], nil]
        end

        def clip(text) = text.to_s[0, 120]
    end

    class Read < Verb
      NAME = "memory_read".freeze
      DESCRIPTION = "Read one memory document (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => PATH_PROPERTY,
        },
        "required" => ["path"],
      }.freeze
      EFFECT_PROFILE = EchoTools::READ_ONLY
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS

      private

        def run(args, scope)
          key, refusal = anchor(args["path"], scope)
          return refuse(refusal, clip(args["path"])) if refusal

          document = Store.read(key)
          return refuse(:memory_not_found, key[2]) if document.nil?

          ok(document)
        end
    end

    class Write < Verb
      NAME = "memory_write".freeze
      DESCRIPTION = "Write one memory document whole (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => PATH_PROPERTY,
          "content" => { "type" => "string", "description" => "The document's complete new text." },
        },
        "required" => %w[path content],
      }.freeze
      EFFECT_PROFILE = MEMORY_WRITE
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS

      private

        def run(args, scope)
          key, refusal = anchor(args["path"], scope, authoring: true)
          return refuse(refusal, clip(args["path"])) if refusal

          content = args.fetch("content")
          Store.write(key, content)
          ok("Wrote #{args.fetch("path")} (#{content.bytesize} bytes).")
        end
    end

    class Unused < Verb
      private

        def run(_args, _scope)
          refuse(:fixture_tool_not_implemented, self.class::NAME)
        end
    end

    class Edit < Unused
      NAME = "memory_edit".freeze
      DESCRIPTION = "Replace one exact passage in a memory document (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => PATH_PROPERTY,
          "old_text" => { "type" => "string", "description" => "Exact text to replace. Must occur exactly once." },
          "new_text" => { "type" => "string", "description" => "Replacement text." },
        },
        "required" => %w[path old_text new_text],
      }.freeze
      EFFECT_PROFILE = MEMORY_EDIT
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS
    end

    class Ls < Verb
      NAME = "memory_ls".freeze
      DESCRIPTION = "List memory document paths (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => { "type" => "string", "description" => "Optional scope or prefix to narrow the listing." },
        },
      }.freeze
      EFFECT_PROFILE = EchoTools::READ_ONLY
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS

      private

        def run(args, scope)
          paths = Store.paths(scope, args.fetch("path", ""))
          ok(paths.empty? ? "No memory documents." : paths.join("\n"))
        end
    end

    class Grep < Unused
      NAME = "memory_grep".freeze
      DESCRIPTION = "Search memory documents for a regular expression (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "pattern" => { "type" => "string", "description" => "Regular expression to match against each line." },
          "path" => { "type" => "string", "description" => "Optional scope or prefix to narrow the search." },
          "ignore_case" => { "type" => "boolean", "description" => "Match case-insensitively." },
          "limit" => { "type" => "integer", "description" => "Maximum matching lines to return." },
        },
        "required" => ["pattern"],
      }.freeze
      EFFECT_PROFILE = EchoTools::READ_ONLY
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS
    end

    class Delete < Unused
      NAME = "memory_delete".freeze
      DESCRIPTION = "Delete one memory document (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => { "path" => PATH_PROPERTY },
        "required" => ["path"],
      }.freeze
      EFFECT_PROFILE = MEMORY_WRITE
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS
    end

    TOOLS = [Read, Write, Edit, Ls, Grep, Delete].freeze

    class << self
      def names = TOOLS.map { |klass| klass::NAME }

      # Runner tools, said so: a provider is a runner process whose rows
      # come from the override, and the base handle admits nothing else.
      # Each verb announces the KERNEL's profile for it — frozen on every
      # row the override addresses here — through the registry's renderer.
      def register(api)
        TOOLS.each { |klass| api.register_tool(klass, serves: :runner) }
      end
    end
  end

  # EVERYTHING THE HARNESS EXECUTOR CAN SERVE: the echo set, the memory
  # set, the guarded echo (`bash`) and the skill echo (`skill`, both named
  # on `--tools` alone) — loaded through the runner gem's loader and
  # announced by the registry's ONE renderer (`ExecutorMain.harness_assembly`).
  module HarnessTools
    MODULES = [EchoTools, MemoryTools, GuardedTools, SkillTools].freeze

    module_function

    def names = MODULES.flat_map(&:names)

    # The `documents` list the announcement carries: the skill module's one document when its
    # `skill` is announced, else nil — the kernel then stores `[]`.
    def documents(selected) = SkillTools.documents(selected)
  end
end
