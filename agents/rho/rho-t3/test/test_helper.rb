$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rho/t3"
require "minitest/autorun"
require "tmpdir"

module T3Test
  Row = Data.define(:public_id, :namespace, :key, :value, :lock_version)
  Page = Data.define(:items, :next_after)
  class Store
    attr_reader :rows
    def initialize = @rows = {}
    def list(**) = Page.new(items: @rows.values, next_after: nil)
    def fetch(id) = @rows.fetch(id)
    def create(namespace:, key:, value:, **)
      id = SecureRandom.uuid_v7
      @rows[id] = Row.new(public_id: id, namespace: namespace, key: key, value: value, lock_version: 0)
    end
    def update(id, value:, lock_version:)
      row = fetch(id)
      raise "stale write" unless row.lock_version == lock_version

      @rows[id] = row.with(value: value, lock_version: lock_version + 1)
    end
    def delete(id, **) = @rows.delete(id)
  end

  class Session
    attr_reader :records, :context, :cancellations
    attr_accessor :active, :on_cancel
    def initialize(store, context)
      @records = Rho::T3::Records.new(store: store, conversation: context.conversation_public_id)
      @context = context
      @active = false
      @cancellations = []
    end
    def owner = { "run" => context.run_public_id, "task" => context.task_key }
    def key = "#{context.run_public_id}:#{context.task_key}"
    def active?(_) = @active
    def cancel(owner)
      @cancellations << owner
      @on_cancel&.call
    end
  end

  class Questions
    attr_reader :calls
    attr_accessor :callback, :answer
    def initialize
      @calls = []
      @answer = "accept"
    end
    def ask(**args)
      @calls << args
      @callback&.call
      { "status" => "completed", "content" => [{ "type" => "text", "text" => @answer }] }
    end
  end

  class Native
    attr_reader :calls
    attr_accessor :document, :uncertain_launch, :partial_launch, :missing, :diff_failure, :providers
    def initialize
      @calls = []
      @document = {
        "thread" => { "id" => "pending", "projectId" => "project", "worktreePath" => "/work/project", "branch" => "main",
          "modelSelection" => { "instanceId" => "native-codex", "model" => "fixture-code" }, "runtimeMode" => "approval-required" },
        "runs" => [{ "id" => "native-run", "ordinal" => 1, "status" => "running",
          "modelSelection" => { "instanceId" => "native-codex", "model" => "fixture-code" } }],
        "messages" => [], "turnItems" => [], "runtimeRequests" => [], "providerSessions" => [], "subagents" => [], "nodes" => [],
      }
    end
    def call(method, params, **)
      @calls << [method, params]
      case method
      when "server.getConfig"
        { "providers" => @providers || T3Test.provider_catalog }
      when "orchestration.launchThread"
        @document.fetch("thread")["id"] = params.fetch("threadId")
        @document.fetch("thread")["modelSelection"] = params.fetch("modelSelection")
        @document.fetch("runs", []).each { |run| run["modelSelection"] = params.fetch("modelSelection") }
        unless partial_launch
          @document.fetch("messages") << { "id" => params.dig("initialMessage", "messageId"), "role" => "user", "text" => params.dig("initialMessage", "text") }
        end
        raise Rho::T3::Uncertain, "response lost" if uncertain_launch

        { "threadId" => params.fetch("threadId"), "projection" => @document, "resumed" => false }
      when "orchestration.getThreadProjection"
        raise Rho::T3::Uncertain, "thread missing" if missing

        @document
      when "orchestration.dispatchCommand"
        case params.fetch("type")
        when "runtime-request.respond" then @document["runtimeRequests"] = []
        when "run.interrupt" then @document.fetch("runs").last["status"] = "interrupted"
        when "message.dispatch"
          @document.fetch("messages") << { "id" => params.fetch("messageId"), "role" => "user", "text" => params.fetch("text") }
          @document.fetch("runs").last["status"] = "running"
        else raise "unexpected native command"
        end
        { "sequence" => 1 }
      when "orchestration.getFullThreadDiff"
        raise Rho::T3::Uncertain, "diff unavailable" if diff_failure

        { "diff" => "+verified fixture change\n" }
      when "orchestration.getTurnItem"
        { "item" => { "type" => "command_execution", "input" => "ruby test.rb", "output" => "All checks passed", "exitCode" => 0 } }
      else raise "unexpected RPC"
      end
    end

    def complete
      @document.fetch("runs").last["status"] = "completed"
      @document.fetch("messages") << { "id" => "answer", "role" => "assistant", "text" => "Implemented and checked" }
      @document.fetch("turnItems") << { "type" => "command_execution", "input" => "ruby test.rb", "exitCode" => 0 }
    end

    def question(kind: "command", prompt: "Run ruby test.rb?", resumable: true)
      @document["runtimeRequests"] = [{ "id" => "question", "nodeId" => "approval-node", "kind" => kind, "status" => "pending",
        "responseCapability" => resumable ? { "type" => "live", "providerSessionId" => "native-session" } : { "type" => "not_resumable", "reason" => "server restarted" } }]
      @document["providerSessions"] = [{ "id" => "native-session", "status" => "waiting", "cwd" => "/work/project" }]
      @document["nodes"] = [{ "id" => "approval-node", "parentNodeId" => "command-node" }]
      @document["turnItems"] = [{ "type" => kind == "user_input" ? "user_input_request" : "approval_request", "requestId" => "question", "prompt" => prompt,
        "questions" => [{ "id" => "color", "question" => "Which color?", "options" => [] }] },
        { "type" => "command_execution", "nodeId" => "command-node", "input" => prompt }]
    end
  end

  def provider_catalog
    [
      { "instanceId" => "native-codex", "driver" => "codex", "enabled" => true, "installed" => true,
        "status" => "ready", "auth" => { "status" => "unknown" }, "models" => [
          { "slug" => "fixture-code", "name" => "Code Model", "isDefault" => true, "aliases" => ["Code"] },
          { "slug" => "fixture-fast", "name" => "Fast Model" },
        ] },
      { "instanceId" => "native-claude", "driver" => "claudeAgent", "enabled" => true, "installed" => true,
        "status" => "ready", "auth" => { "status" => "authenticated" }, "models" => [
          { "slug" => "fixture-review", "name" => "Review Model", "isDefault" => true, "aliases" => ["Review"] },
        ] },
    ]
  end
  module_function :provider_catalog

  def settings(**changes)
    Rho::T3::Settings.parse({ "url" => "http://localhost:3773", "project_id" => "project",
      "default_agent" => "Codex" }.merge(changes.transform_keys(&:to_s)), env: { "RHO_T3_TOKEN" => "fixture-bearer" })
  end

  def with_work(store: Store.new, native: Native.new, task: "tool", config: settings, sleeper: nil)
    Dir.mktmpdir do |root|
      questions = Questions.new
      context = Rho::Runner::ExecutionContext.new(run_public_id: "run", conversation_public_id: "conversation", task_key: task, orchestration: questions)
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(root, "artifacts"))
      session = Session.new(store, context)
      work = Rho::T3::Work.new(settings: config, session: session, env: env, home: nil, bridge: native,
        sleeper: sleeper || -> { native.complete })
      Rho::Runner::ExecutionContext.with(context) { yield work, native, store, context, questions, session }
    end
  end
end
