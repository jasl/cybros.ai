module RhoTest
  module EnvironmentFixtures
    NAMESPACE = "rho.environment".freeze
    KEY = "binding/agent".freeze

    # ---- the SDK doubles ----

    # One conversation's store door: the four verbs with the kernel's
    # rules — a singleton per (namespace, key) (`key_taken`), the
    # `lock_version` compare on update and delete (`stale_object`), the
    # summary on `list`, the value on `fetch`. Every call is recorded.
    class FakeStore
      attr_reader :rows, :calls

      def initialize(rows = [])
        @rows = rows
        @calls = []
        @sequence = rows.length
        @fail_reads = nil
      end

      def fail_reads(error) = @fail_reads = error

      def entry(namespace = NAMESPACE, key = KEY) = @rows.find { |row| row.namespace == namespace && row.key == key }

      def list(after: nil, limit: nil)
        @calls << [:list, after]
        raise @fail_reads if @fail_reads

        CybrosAgent::Api::Page.new(items: @rows.map { |row| summary(row) }, next_after: nil)
      end

      def fetch(public_id)
        @calls << [:fetch, public_id]
        raise @fail_reads if @fail_reads

        @rows.find { |row| row.public_id == public_id } ||
          raise(CybrosAgent::Api::NotFound.new("no entry #{public_id}", code: "not_found"))
      end

      def create(namespace:, key:, value:, idempotency_key:)
        @calls << [:create, namespace, key, value, idempotency_key]
        raise CybrosAgent::Api::Conflict.new("taken", code: "key_taken") if entry(namespace, key)

        @sequence += 1
        row = CybrosAgent::Api::StoreEntry.new(public_id: "se-#{@sequence}", namespace: namespace, key: key,
          lock_version: 0, created_at: "2026-09-17T00:00:00Z", updated_at: "2026-09-17T00:00:00Z", value: value)
        @rows << row
        row
      end

      def update(public_id, value:, lock_version:)
        @calls << [:update, public_id, value, lock_version]
        row = row_of(public_id)
        raise CybrosAgent::Api::Conflict.new("stale", code: "stale_object") unless row.lock_version == lock_version

        updated = row.with(value: value, lock_version: lock_version + 1, updated_at: "2026-09-17T00:00:01Z")
        @rows = @rows.map { |candidate| candidate.equal?(row) ? updated : candidate }
        updated
      end

      def delete(public_id, lock_version:)
        @calls << [:delete, public_id, lock_version]
        row = row_of(public_id)
        raise CybrosAgent::Api::Conflict.new("stale", code: "stale_object") unless row.lock_version == lock_version

        @rows = @rows.reject { |candidate| candidate.equal?(row) }
        nil
      end

      # A person's PATCH through the SDK between two turns.
      def patch(value)
        row = entry
        @rows = @rows.map { |candidate| candidate.equal?(row) ? row.with(value: value, lock_version: row.lock_version + 1) : candidate }
      end

      private

        # The fake's own lookups record nothing: `calls` is what rho asked.
        def row_of(public_id)
          @rows.find { |row| row.public_id == public_id } ||
            raise(CybrosAgent::Api::NotFound.new("no entry #{public_id}", code: "not_found"))
        end

        def summary(row)
          CybrosAgent::Api::StoreEntrySummary.new(public_id: row.public_id, namespace: row.namespace, key: row.key,
            lock_version: row.lock_version, created_at: row.created_at, updated_at: row.updated_at)
        end
    end

    Parent = Data.define(:public_id)
    Projection = Data.define(:parent, :default_runner)

    # A conversation on the member plane: its store, its projection (the
    # parent for the walk, the runner for the child edge).
    class FakeConversation
      attr_reader :fetches

      def initialize(store: FakeStore.new, parent: nil, runner: nil, missing: false)
        @store = store
        @parent = parent
        @runner = runner
        @missing = missing
        @fetches = 0
      end

      # A conversation this principal may not see conceals its store too.
      def store_entries
        raise CybrosAgent::Api::NotFound.new("gone", code: "not_found") if @missing

        @store
      end

      def fetch
        @fetches += 1
        raise CybrosAgent::Api::NotFound.new("gone", code: "not_found") if @missing

        Projection.new(parent: @parent && Parent.new(public_id: @parent),
          default_runner: @runner && CybrosAgent::Api::DefaultRunner.new(executor_public_id: @runner, display_name: nil,
            presence: "offline", last_seen_at: nil))
      end
    end

    # The request run a call_tool creates: the scripted terminal detail.
    class FakeRequest
      def initialize(detail) = @detail = detail

      def wait_for_tool_result(poll:) = @detail
    end

    class FakeHostFollowers
      attr_reader :requests

      def initialize(answers)
        @answers = answers
        @requests = []
      end

      def start_tool_call(runner_executor_public_id:, tool:, idempotency_key:, input: {}, timeout_ms: nil, approval_rules: nil)
        @requests << { runner: runner_executor_public_id, tool: tool, input: input, timeout_ms: timeout_ms,
                       rules: approval_rules, key: idempotency_key }
        FakeRequest.new(@answers.shift || raise("no scripted answer for #{tool} on #{runner_executor_public_id}"))
      end
    end

    class FakeWorkspace
      def initialize(conversations, runs)
        @conversations = conversations
        @host_followers = runs
      end

      def conversation(public_id) = @conversations.fetch(public_id) { FakeConversation.new(missing: true) }

      def runs = @host_followers
    end

    class FakeExecutors
      attr_reader :shows

      def initialize(documents)
        @documents = documents
        @shows = []
      end

      def show(public_id)
        @shows << public_id
        @documents.fetch(public_id) { raise CybrosAgent::Api::NotFound.new("no executor", code: "not_found") }
      end
    end

    class FakeClient
      attr_reader :executors

      def initialize(conversations: {}, answers: [], executors: {})
        @workspace = FakeWorkspace.new(conversations, FakeHostFollowers.new(answers))
        @executors = FakeExecutors.new(executors)
      end

      def workspace(_public_id) = @workspace

      def requests = @workspace.runs.requests
    end

    # ---- the fixtures ----

    def setup
      @root = Dir.mktmpdir("rho-environments")
      @project = File.join(@root, "project")
      @other = File.join(@root, "other")
      FileUtils.mkdir_p(@project)
      FileUtils.mkdir_p(@other)
      @home = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "home"))
      @home.prepare
      @log = Rho::Log.to_file(File.join(@root, "rho.log"))
      @spawned = []
    end

    def teardown
      FileUtils.remove_entry(@root) if File.directory?(@root)
    end

    def log_text = File.read(File.join(@root, "rho.log"), encoding: Encoding::UTF_8)

    def registry = @registry ||= Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry

    # The host's tables over a scripted client. `spawn:` runs the call_tool
    # fiber's block on a thread, so the gate has something to wait on;
    # `inline: true` runs it before the gate is reached.
    def environments(client, own: "0199-runner", inline: false, learned: [], booted_at: "2026-09-17T08:00:00Z",
                     default_root: -> { @project }, member_plane: :own)
      plane = Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: "ws-1")
      Rho::Environments.new(
        home: @home, config: Rho::Config.from_hash({}), registry: registry, log: @log, clock: -> { Time.now },
        booted_at: booted_at, default_root: default_root,
        member_plane: (member_plane == :own ? ->(**) { plane } : member_plane), own_runner: ->(id) { id == own },
        learn_runner: ->(document) { learned << document },
        spawn: ->(&work) { inline ? work.call : (@spawned << Thread.new(&work)) }
      )
    end

    def plane(client) = Rho::Extensions::MemberPlane.new(client: client, workspace_public_id: "ws-1")

    def binding(root = @project, directories: [], anchor: "c-1")
      Rho::Runner::Environment::Binding.new(root: root, directories: directories, anchor: anchor)
    end

    def value(root = @project, directories: [], anchor: "c-1")
      { "root" => root, "directories" => directories, "anchor" => anchor }
    end

    def row(value, public_id: "se-1", lock_version: 0, key: KEY)
      CybrosAgent::Api::StoreEntry.new(public_id: public_id, namespace: NAMESPACE, key: key, lock_version: lock_version,
        created_at: "2026-09-17T00:00:00Z", updated_at: "2026-09-17T00:00:00Z", value: value)
    end

    # The scripted call_tool answer: the task terminal as the runner left it.
    def relay_answer(status: "completed", error_key: nil, applied: true, resolved: true, booted_at: "2026-09-17T07:00:00Z",
                     is_error: false)
      task = CybrosAgent::Api::RunTask.new(
        key: "call_tool", kind: "tool_task", lifetime: "conversation", wake: "auto", status: status, tool_name: "environment_bind", on_failure: "halt",
        failure_resolution: nil, visibility: "visible", created_at: "2026-09-17T00:00:00Z", started_at: nil,
        completed_at: nil, error: (error_key && { "key" => error_key }),
        result: (status == "completed" ? { "is_error" => is_error } : nil)
      )
      CybrosAgent::Api::RunTaskDetail.new(task: task, output: "bound", content: nil,
        structured_content: (status == "completed" && !is_error ? { "applied" => applied, "resolved" => resolved, "booted_at" => booted_at } : nil))
    end

    def discovered(public_id, booted_at: nil, connected_at: nil, root: "/srv/elsewhere")
      environment = { "root" => root }
      environment["booted_at"] = booted_at if booted_at
      CybrosAgent::Api::DiscoveredExecutor.new(public_id: public_id, kind: "runner", display_name: "Elsewhere",
        status: "active", assignment_scope: "user_private", served_tools: [], environment: environment,
        served_documents: [], presence: "online", last_seen_at: nil, connected_at: connected_at)
    end

    def join_spawned = @spawned.each(&:join)

    # A claimed row as the runner gem's `Toolsets#for` reads it.
    Task = Data.define(:conversation_public_id, :parent_public_id, :run_public_id)

    def task(conversation, parent: nil, run_public_id: "al-1")
      Task.new(conversation_public_id: conversation, parent_public_id: parent, run_public_id: run_public_id)
    end
  end
end
