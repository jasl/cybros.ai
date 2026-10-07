require "json"
require "time"
require_relative "echo_tools"
require_relative "guarded_tools"

module E2E
  # THE SAMPLE TOOLS PROVIDER'S MEMORY: the six kernel memory verbs served from an in-memory store
  # keyed by the row's named database bindings and the document's name, never by `tool_input` alone:
  # two workspaces' `workspace/notes.md` are two documents, and a `user/` document belongs to the
  # stamped person. A row without the stamp is refused, never guessed at.
  #
  # The result TEXT mirrors `AgentRuns::Memory::Run` line for line, so a
  # mock transcript reads the same whichever authority answered — and X6's
  # assertions on the provider's rows are the kernel's own spellings.
  # Registered through the runner gem's extension door beside `EchoTools`;
  # a provider is a runner process whose rows come from the override.
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
    MAX_READ_LINES = 2_000
    # `ls` and `grep` default and ceiling (`MemoryDocuments::Search`).
    DEFAULT_GREP_LIMIT = 100
    MAX_GREP_LIMIT = 500

    PATH_PROPERTY = { "type" => "string", "description" => "Scoped path, e.g. workspace/notes.md" }.freeze

    Binding = Data.define(:name, :scope, :access, :public_id) do
      def self.from_h(value)
        scope = value.fetch("scope")
        new(name: value.fetch("name"), scope: scope, access: value.fetch("access"),
          public_id: value.fetch("#{scope}_public_id"))
      end

      def key = [scope, public_id]
    end

    # ONE PROCESS-WIDE STORE, replaced whole under a mutex: a document is
    # `[scope, scope_id, name] => Document`, and a listing is a scan.
    module Store
      Document = Data.define(:content, :written_at)
      Entry = Data.define(:path, :content, :written_at)

      MUTEX = Mutex.new
      @documents = {}.freeze

      module_function

      def read(key) = MUTEX.synchronize { @documents[key] }

      def write(key, content)
        MUTEX.synchronize do
          document = Document.new(content: content, written_at: Time.now.utc)
          @documents = @documents.merge(key => document).freeze
          document
        end
      end

      # The exact passage is checked and replaced under the same lock.
      # A concurrent writer cannot move the document between those steps.
      def edit(key, old_text:, new_text:)
        MUTEX.synchronize do
          document = @documents[key]
          return [:memory_not_found, key[2]] if document.nil?
          return [:memory_edit_invalid, "old_text is required"] if old_text.empty?

          occurrences = document.content.scan(old_text).length
          return [:memory_edit_not_found, old_text[0, 80]] if occurrences.zero?
          return [:memory_edit_ambiguous, "#{occurrences} occurrences"] if occurrences > 1

          changed = Document.new(content: document.content.sub(old_text) { new_text }, written_at: Time.now.utc)
          @documents = @documents.merge(key => changed).freeze
          [nil, nil]
        end
      end

      # Nil when there was nothing to delete.
      def delete(key)
        MUTEX.synchronize do
          document = @documents[key]
          @documents = @documents.except(key).freeze if document
          document
        end
      end

      # One database anchor may have multiple logical names. Listings expose
      # each supplied name without copying the document into separate stores.
      def entries(bindings, prefix = nil)
        snapshot = MUTEX.synchronize { @documents }
        snapshot.flat_map do |(scope, scope_id, name), document|
          next [] if prefix && !name.start_with?(prefix)

          bindings.filter_map do |binding|
            if binding.key == [scope, scope_id]
              Entry.new(path: "#{binding.name}/#{name}", content: document.content, written_at: document.written_at)
            end
          end
        end.sort_by(&:path)
      end

      def clear! = MUTEX.synchronize { @documents = {}.freeze }
    end

    # The handler every memory verb shares: cancellation honoured at the
    # one checkpoint, the row's stamp read off the bound context, a path
    # resolved to `[scope, scope_id, name]` the way `Scopes::Anchor` does,
    # and the kernel's refusal form (`code: detail`, is_error).
    class Verb
      def initialize(env:)
        @env = env
      end

      def call(args)
        Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
        scope = Rho::Runner::ExecutionContext.current&.scope
        return refuse(:memory_scope_unavailable, "no scope on the row") if scope.nil?

        run(Hash.try_convert(args) || {}, scope.fetch("bindings").map { |entry| Binding.from_h(entry) })
      end

      private

        def refuse(code, detail = nil) = Rho::Runner::Result.error([code, detail].compact.join(": "))

        def ok(text) = Rho::Runner::Result.ok(text)

        # The bare name is refused rather than defaulted, and a scope whose
        # id the stamp lacks (a standalone row's conversation) is refused
        # as data — the kernel's two answers.
        def anchor(path, bindings, authoring: false)
          scope_name, name = String.try_convert(path).to_s.split("/", 2)
          return [nil, :memory_path_invalid] if name.to_s.empty?

          binding = bindings.find { |entry| entry.name == scope_name }
          return [nil, :memory_scope_unavailable] if binding.nil?
          return [nil, :memory_read_only] if authoring && binding.access != "read_write"

          [[*binding.key, name], nil]
        end

        def clip(text) = String.try_convert(text).to_s[0, 120]
    end

    class Read < Verb
      NAME = "memory_read".freeze
      DESCRIPTION = "Read one memory document (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => PATH_PROPERTY,
          "offset" => { "type" => "integer", "description" => "1-indexed line number to start reading from" },
          "limit" => { "type" => "integer", "description" => "Maximum number of lines to read" },
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

          ok(slice(document.content, args))
        end

        # The kernel's slice: `offset`/`limit` honoured, the tail naming
        # where to continue when the read was cut.
        def slice(content, args)
          offset = Integer(args["offset"], exception: false)
          limit = Integer(args["limit"], exception: false) || MAX_READ_LINES
          lines = content.each_line.to_a
          lines = lines.drop((offset - 1).clamp(0..)) if offset
          shown = lines.take(limit.clamp(..MAX_READ_LINES))
          text = shown.join
          return text if shown.length == lines.length

          "#{text}\n[Showing #{shown.length} of #{lines.length} lines. " \
            "Continue with offset=#{(offset || 1) + shown.length}.]"
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

          content = String.try_convert(args["content"])
          return refuse(:memory_content_invalid, key[2]) if content.nil?

          Store.write(key, content)
          ok("Wrote #{args.fetch("path")} (#{content.bytesize} bytes).")
        end
    end

    class Edit < Verb
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

      private

        # Exactly-once replace: a passage that appears twice cannot be
        # edited without guessing which one was meant.
        def run(args, scope)
          key, refusal = anchor(args["path"], scope, authoring: true)
          return refuse(refusal, clip(args["path"])) if refusal

          refusal, detail = Store.edit(key, old_text: String.try_convert(args["old_text"]).to_s,
            new_text: String.try_convert(args["new_text"]).to_s)
          return refuse(refusal, detail) if refusal

          ok("Edited #{args.fetch("path")}.")
        end
    end

    # `ls` and `grep` take a PREFIX rather than a path: an empty one is the
    # union of the scopes this row can see, a bare `workspace/` one rung,
    # `workspace/no` a name prefix inside it.
    class Listing < Verb
      private

        def listing_scope(args, bindings)
          raw = String.try_convert(args["path"]).to_s
          return [bindings, nil, nil] if raw.empty?

          scope_name, name = raw.split("/", 2)
          binding = bindings.find { |entry| entry.name == scope_name }
          return [nil, nil, :memory_scope_unavailable] if binding.nil?

          [[binding], name.to_s.empty? ? nil : name, nil]
        end
    end

    class Ls < Listing
      NAME = "memory_ls".freeze
      DESCRIPTION = "List memory documents with sizes and ages (E2E sample provider — keyed by the row's scope).".freeze
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
          keys, prefix, refusal = listing_scope(args, scope)
          return refuse(refusal, clip(args["path"])) if refusal

          entries = Store.entries(keys, prefix)
          return ok("No memory documents.") if entries.empty?

          ok(entries.map { |entry| "#{entry.path}  #{entry.content.bytesize} bytes  #{entry.written_at.iso8601}" }.join("\n"))
        end
    end

    class Grep < Listing
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

      private

        def run(args, scope)
          keys, prefix, refusal = listing_scope(args, scope)
          return refuse(refusal, clip(args["path"])) if refusal

          pattern = String.try_convert(args["pattern"]).to_s
          matcher = compile(pattern, args["ignore_case"] == true)
          return refuse(:memory_pattern_invalid, pattern[0, 80]) if matcher.nil?

          bound = (Integer(args["limit"] || DEFAULT_GREP_LIMIT, exception: false) || DEFAULT_GREP_LIMIT)
            .clamp(1, MAX_GREP_LIMIT)
          lines, truncated = scan(Store.entries(keys, prefix), matcher, bound)
          return ok("No matches found.") if lines.empty?

          lines += ["[Result limit reached. Narrow the pattern or raise limit=.]"] if truncated
          ok(lines.join("\n"))
        end

        def compile(pattern, ignore_case)
          return nil if pattern.empty?

          Regexp.new(pattern, ignore_case ? Regexp::IGNORECASE : 0)
        rescue RegexpError
          nil
        end

        # Path order, then line — no score, because there is none.
        def scan(entries, matcher, bound)
          found = entries.flat_map do |entry|
            entry.content.each_line.with_index(1).filter_map do |line, number|
              "#{entry.path}:#{number}: #{line.chomp}" if matcher.match?(line)
            end
          end
          [found.first(bound), found.length > bound]
        end
    end

    class Delete < Verb
      NAME = "memory_delete".freeze
      DESCRIPTION = "Delete one memory document (E2E sample provider — keyed by the row's scope).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => { "path" => PATH_PROPERTY },
        "required" => ["path"],
      }.freeze
      EFFECT_PROFILE = MEMORY_WRITE
      TIMEOUT_MS = MemoryTools::TIMEOUT_MS

      private

        def run(args, scope)
          key, refusal = anchor(args["path"], scope, authoring: true)
          return refuse(refusal, clip(args["path"])) if refusal
          return refuse(:memory_not_found, key[2]) if Store.delete(key).nil?

          ok("Deleted #{args.fetch("path")}.")
        end
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
