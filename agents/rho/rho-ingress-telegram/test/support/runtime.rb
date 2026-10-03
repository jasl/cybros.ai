require "test_helper"
require "tmpdir"
require "fileutils"

module TelegramRuntimeSupport
  def self.turn_id(conversation_id, position)
    conversation_id == "conversation-1" ? "turn-#{position}" : "#{conversation_id}-turn-#{position}"
  end

  class Bridge
    attr_reader :opened, :stops, :decisions, :speakers, :open_workspaces, :created_workspaces
    attr_accessor :turn_rows, :pending_rows, :current, :fail_input, :fail_stop,
      :workspace_rows, :default_workspace, :workspace_selection, :fail_workspace, :fail_open, :read_failure,
      :queue_rows, :fail_input_control, :event_rows, :defer_inputs, :declared_tools, :execution_tools
    attr_reader :queue_reads, :queue_writes, :stop_calls, :loop_workspaces, :memory_bindings, :memory_anchors

    def initialize
      @inputs, @opened, @stops, @decisions, @speakers = {}, {}, [], [], []
      @turn_rows, @pending_rows = {}, []
      @current = { "sequence" => 1, "status" => "running", "loop_public_id" => "loop-1", "action" => "running a command" }
      @workspace_rows = [{ "public_id" => "workspace-home", "name" => "Home", "status" => "active" },
        { "public_id" => "workspace-project", "name" => "Project", "status" => "active" }]
      @default_workspace = @workspace_rows.first
      @open_workspaces, @created_workspaces = {}, {}
      @queue_rows, @queue_reads, @queue_writes = {}, [], []
      @event_rows = {}
      @stop_calls, @loop_workspaces, @sides = [], {}, {}
      @memory_bindings, @memory_anchors = {}, {}
      @declared_tools = { false => %w[bash read write edit ls find grep task compose wait ask],
        true => %w[bash read write edit ls find grep task compose wait ask] }
      @execution_tools = Hash.new(["read", "task", "ask"])
    end

    def open(idempotency_key:, group:, isolated: false, workspace_public_id: nil, memory_context: nil)
      id = @opened[idempotency_key] ||= "conversation-#{@opened.length + 1}"
      @open_workspaces[id] = workspace_public_id
      @memory_bindings[id] = memory_context
      if @fail_open
        @fail_open = false
        raise Rho::ConnectionError, "conversation accepted but response lost"
      end
      id
    end

    def open_memory_anchor(idempotency_key:, title:, workspace_public_id:)
      id = @memory_anchors[idempotency_key] ||= "memory-#{@memory_anchors.length + 1}"
      @open_workspaces[id] = workspace_public_id
      id
    end

    def bind_memory(id, memory_context:, workspace_public_id:)
      @memory_bindings[id] = memory_context
    end

    def attach(id, workspace_public_id:)
      @open_workspaces[id] = workspace_public_id
      { "run" => @current }
    end

    def participation_memory(id, model:, workspace_public_id:) = nil

    def workspaces = @workspace_rows
    def read_only_tool_names(group:) = @declared_tools.fetch(group) & Rho::IngressTelegram::GroupProfile::READ_ONLY_TOOLS
    def read_only_execution?(id, workspace_public_id:)
      names = @execution_tools[id]
      !names.nil? && (names - Rho::IngressTelegram::GroupProfile::READ_ONLY_TOOLS).empty?
    end

    def open_side(parent:)
      id = @sides[parent] ||= "side-#{@sides.length + 1}"
      @open_workspaces[id] = @open_workspaces.fetch(parent)
      id
    end
    def workspace_state
      { "workspaces" => @workspace_rows, "workspace" => @default_workspace, "selection" => @workspace_selection }
    end
    def workspace(id) = @workspace_rows.find { |row| row.fetch("public_id") == id } || raise(Rho::Error, "Workspace not available")

    def create_workspace(name:, idempotency_key:)
      row = @created_workspaces[idempotency_key] ||= { "public_id" => "workspace-created-#{@created_workspaces.length + 1}",
        "name" => name, "status" => "active" }
      @workspace_rows |= [row]
      if @fail_workspace
        @fail_workspace = false
        raise Rho::ConnectionError, "workspace accepted but response lost"
      end
      row
    end

    def conversation_workspace(id)
      @workspace_rows.find { |row| row.fetch("public_id") == @open_workspaces.fetch(id) }
    end

    def conversation_workspace_id(id) = @open_workspaces.fetch(id)

    def register_speaker(bot_id:, user:)
      @speakers << [bot_id, user]
      "speaker-#{user.fetch("id")}"
    end

    def submit(id, **request)
      @inputs[request.fetch(:idempotency_key)] ||= request.merge(conversation_id: id)
      if @fail_input
        @fail_input = false
        raise Rho::ConnectionError, "response lost after acceptance"
      end
      number = @inputs.keys.index(request.fetch(:idempotency_key)) + 1
      result = { "input" => { "public_id" => "input-#{number}" } }
      result.fetch("input")["deliver_at"] = request[:deliver_at] if request[:deliver_at]
      unless request[:observe] || @defer_inputs || request[:deliver_at]
        position = @inputs.values.take(number).count { |row| row.fetch(:conversation_id) == id && !row[:observe] } - 1
        result.merge!("turn" => { "public_id" => TelegramRuntimeSupport.turn_id(id, position) }, "loop" => { "public_id" => "loop-#{number}" })
        @loop_workspaces["loop-#{number}"] = request[:workspace_public_id]
      end
      result
    end

    def turns(id, after_position: nil, workspace_public_id: nil)
      raise @read_failure if @read_failure

      @turn_rows.fetch(id, []).select { |row| after_position.nil? || row.fetch("position") > after_position }
    end

    def turn_source(id, position:, workspace_public_id: nil)
      raise @read_failure if @read_failure

      @turn_rows.fetch(id, []).find { |row| row.fetch("position") == position }
    end

    def turn_media(_turn, workspace_public_id:) = []

    def events(id, after: nil, workspace_public_id: nil)
      rows = @event_rows.fetch(id, [])
      index = rows.index { |row| row.fetch("cursor") == after }
      { "events" => index ? rows.drop(index + 1) : rows,
        "pagination" => { "next_after" => nil, "watermark" => rows.last&.fetch("sequence") || 0 } }
    end

    def observation(id, workspace_public_id:)
      @inputs.values.select { |row| row.fetch(:conversation_id) == id && row[:observe] }.map { |row| row.fetch(:text) }.join("\n")
    end

    def runs = @opened.values.to_h { |id| [id, @current] }
    def progress(run) = run
    def snapshot(_id, workspace_public_id: nil, run: nil, inputs: nil) = @current
    def pending(_id, workspace_public_id: nil, reads: nil) = @pending_rows
    def models = ["vendor/model"]
    def scheduled_jobs(_id, after: nil, workspace_public_id:)
      { "scheduled_jobs" => [], "pagination" => { "next_after" => nil } }
    end

    def inputs(id = nil, workspace_public_id: nil)
      return @inputs unless id

      @queue_reads << [id, workspace_public_id]
      @queue_rows.fetch(id, [])
    end

    def update_input(id, input_id, text: nil, schedule: {}, workspace_public_id:)
      @queue_writes << if schedule.empty?
        [:edit, id, input_id, text, workspace_public_id]
      else
        [:reschedule, id, input_id, schedule, workspace_public_id]
      end
      row = @queue_rows.fetch(id).find { |input| input.fetch("public_id") == input_id }
      row["text"] = text if text
      row.merge!(schedule).merge!("state" => "pending")
      fail_input_control_response
      row
    end

    def delete_input(id, input_id, workspace_public_id:)
      @queue_writes << [:cancel, id, input_id, workspace_public_id]
      @queue_rows.fetch(id).delete_if { |input| input.fetch("public_id") == input_id }
      fail_input_control_response
      nil
    end

    def conversation(id, workspace_public_id:)
      { "public_id" => id, "title" => "A useful conversation" }
    end

    def fail_input_control_response
      if @fail_input_control
        @fail_input_control = false
        raise Rho::ConnectionError, "queue control accepted but response lost"
      end
    end

    def stop(id, host_type: "conversation", workspace_public_id: nil)
      @stops << id
      @stop_calls << [id, host_type, workspace_public_id]
      if @fail_stop
        @fail_stop = false
        raise Rho::ConnectionError, "stop accepted but response lost"
      end
    end
    def approve(id, key, workspace_public_id: nil) = @decisions << ["approve", id, key, workspace_public_id]
    def deny(id, key, workspace_public_id: nil) = @decisions << ["deny", id, key, workspace_public_id]
    def answer(id, key, text, workspace_public_id: nil) = @decisions << ["answer", id, key, text, workspace_public_id]
  end

  class Client
    attr_reader :calls, :last_message_id
    attr_accessor :failure, :admin, :privacy_disabled

    def initialize
      @calls = []
      @admin = false
    end

    def call(method, params = {}, poll: false)
      @calls << [method, params]
      if @failure
        error, @failure = @failure, nil
        raise error
      end
      return { "status" => @admin ? "administrator" : "member" } if method == "getChatMember"
      return { "id" => 42, "username" => "rho_bot", "can_read_all_group_messages" => !!@privacy_disabled } if method == "getMe"
      return { "file_path" => "photos/synthetic.jpg" } if method == "getFile"

      @last_message_id = 1_000 + @calls.length
      { "message_id" => @last_message_id }
    end
  end

  def setup
    @directory = Dir.mktmpdir("rho-telegram-runtime")
    File.chmod(0o700, @directory)
    @home = Struct.new(:root).new(@directory)
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @state.change { |document| document["access"] = { "allowed_users" => ["2"], "allowed_chats" => ["-10"], "ignored_users" => [] } }
    @settings = Rho::IngressTelegram::Settings.new(
      { "owner_id" => 1 },
      env: { "RHO_TELEGRAM_BOT_TOKEN" => "fake-token" }
    )
    @bridge, @client = Bridge.new, Client.new
    @now = 1_000.0
    @runtime = runtime
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  private

    def runtime(default_model: nil)
      logger = Object.new
      logger.define_singleton_method(:warn) { |*| }
      result = Rho::IngressTelegram::Runtime.new(settings: @settings, state: @state, bridge: @bridge,
        client: @client, log: logger, default_model: default_model, clock: -> { @now })
      result.identify("id" => 42, "username" => "rho_bot")
      result
    end

    def telegram_message(id, text, user: 1, chat: nil, topic: nil, entities: [], date: 1_000, reply_to: nil, reply_user: 42)
      chat ||= user
      { "update_id" => id, "message" => { "message_id" => id, "date" => date, "text" => text,
        "from" => { "id" => user, "first_name" => "Person #{user}" },
        "chat" => { "id" => chat, "type" => chat.negative? ? "supergroup" : "private" },
        "message_thread_id" => topic, "is_topic_message" => (true if topic), "entities" => entities,
        "reply_to_message" => ({ "message_id" => reply_to, "from" => { "id" => reply_user } } if reply_to) }.compact }
    end

    def turn(position, text, status: "completed", conversation_id: "conversation-1")
      { "public_id" => TelegramRuntimeSupport.turn_id(conversation_id, position), "position" => position,
        "variant_public_id" => "#{conversation_id}-variant-#{position}",
        "kind" => "direct_reply", "status" => status, "text" => text }
    end
end
