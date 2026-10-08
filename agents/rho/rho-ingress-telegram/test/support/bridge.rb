module TelegramBridgeSupport
  Host = Data.define(:home, :member_plane)
  Page = Data.define(:items, :next_after)
  HeldLoop = Data.define(:public_id, :turn, :tasks) do
    def repairable_tasks
      tasks.select { |task| %w[failed timed_out uncertain].include?(task.status) && task.failure_resolution.nil? && task.on_failure != "absorb" }
    end
  end
  TurnOwner = Data.define(:conversation_public_id)
  Task = Data.define(:key, :status, :kind, :addressed_to, :error, :on_failure, :failure_resolution) do
    def initialize(kind: "tool_task", addressed_to: nil, error: nil, on_failure: nil, failure_resolution: nil, **) = super
    def await? = kind == "await_task"
  end
  Parent = Data.define(:public_id)
  RunnerSelection = Data.define(:executor_public_id)
  Conversation = Data.define(:parent, :default_runner) do
    def initialize(parent:, default_runner: nil) = super
  end
  Agent = Data.define(:name, :public_id, :derived_from_public_id)
  Configuration = Data.define(:tool_definitions, :kernel_tools, :runner_executor_public_ids, :runner_tool_names) do
    def initialize(tool_definitions:, kernel_tools: [], runner_executor_public_ids: [], runner_tool_names: nil) = super
  end
  Profile = Data.define(:member, :configuration)
  Resource = Data.define(:row) do
    def fetch = row
    def list = row
  end
  LoopResource = Data.define(:row, :task_details, :calls) do
    def fetch = row
    def task(key)
      calls << [:task, row.public_id, key]
      task_details.fetch([row.public_id, key])
    end
  end

  class Core
    attr_reader :calls
    attr_writer :asks
    attr_accessor :turn_rows, :run, :input_rows, :conversation_workspace_id, :run_rows

    def initialize
      @calls, @turn_rows, @asks, @run, @input_rows = [], [], [], {}, []
      @conversation_workspace_id = "workspace"
      @run_rows = []
    end

    def say(id, text, **options)
      @calls << [:say, id, text, options]
      { "input" => { "public_id" => "input", "state" => "pending" }, "pending" => true }
    end
    def open_conversation(**options)
      @calls << [:open, options]
      { "conversation" => { "public_id" => "conversation" } }
    end
    def turns(id, **options)
      @calls << [:turns, id, options]
      { "turns" => @turn_rows }
    end
    def attach(id, **options)
      @calls << [:attach, id, options]
      { "run" => @run }
    end
    def followers
      @calls << [:followers]
      @run_rows
    end
    def asks
      @calls << [:asks]
      @asks
    end
    def inputs(id, **options)
      @calls << [:inputs, id, options]
      @input_rows
    end
    def schedules(id, **options)
      @calls << [:schedules, id, options]
      { "schedules" => [], "pagination" => { "next_after" => nil } }
    end
    def conversation(id)
      @calls << [:conversation, id]
      { "workspace_public_id" => @conversation_workspace_id }
    end
    def workspaces
      { "workspaces" => [workspace("workspace")], "workspace" => workspace("workspace"), "selection" => nil }
    end
    def workspace(id)
      @calls << [:workspace, id]
      { "public_id" => id, "name" => "Home" }
    end
    def create_workspace(**options)
      @calls << [:create_workspace, options]
      { "public_id" => "created", "name" => options.fetch(:name) }
    end
    def stop(id, **options) = @calls << [:stop, id, options]
    def approve(id, key, **options) = @calls << [:approve, id, key, options]
    def deny(id, key, **options) = @calls << [:deny, id, key, options]
    def answer(id, key, text, **options) = @calls << [:answer, id, key, text, options]
  end

  class Member
    attr_accessor :named_agents, :loops, :parents, :more, :tool_definitions, :task_details, :runner_selections, :assembled_tools, :configuration
    attr_reader :calls

    def initialize
      @calls, @named_agents, @loops, @parents, @more = [], [], [], {}, nil
      @tool_definitions = []
      @task_details = {}
      @runner_selections, @assembled_tools = {}, {}
    end

    def profile = self
    def agents = Resource.new(row: @named_agents)
    def tools = self
    def assemble(default_runner_executor_public_id:, configuration:)
      @calls << [:assemble, { default_runner_executor_public_id: default_runner_executor_public_id, configuration: configuration }]
      CybrosAgent::Api::ToolAssembly.new(tool_definitions: @assembled_tools.fetch(default_runner_executor_public_id), environment: {})
    end
    def fetch = Profile.new(member: Parent.new(public_id: "own"), configuration: @configuration || Configuration.new(tool_definitions: @tool_definitions))
    def workspace(id)
      @calls << [:workspace, id]
      self
    end
    def runs = self
    def list(**options)
      @calls << [:list, options]
      Page.new(items: @loops, next_after: @more)
    end
    def run(id)
      @calls << [:run, id]
      LoopResource.new(row: @loops.find { |row| row.public_id == id }, task_details: @task_details, calls: @calls)
    end
    def conversation(id)
      @calls << [:conversation, id]
      Resource.new(row: Conversation.new(parent: (Parent.new(public_id: @parents.fetch(id)) if @parents.fetch(id)),
        default_runner: @runner_selections[id]))
    end
    def register_ingress_speaker(**options)
      @calls << [:register_ingress_speaker, options]
      Parent.new(public_id: "speaker")
    end
  end
end
