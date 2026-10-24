# A diagnostic author inside the paired rho process. Core opens and binds the
# conversation; each diagnostic input captures its selected tools through the SDK.
module ToolCatalogAuthor
  NAME = "e2e.tool-catalog-author".freeze
  TOOL_FIELDS = %w[tool_definitions kernel_tools runner_executor_public_ids runner_tool_names].freeze

  def self.register(api)
    selected = nil
    documents = nil
    api.register_route("GET", "/e2e/tool-catalog") do |request, ctx|
      ctx.member_plane(request) do |client, *|
        [200, { "configuration" => selected || tool_sources(client),
          "prompt_documents" => prompt_documents(client) }]
      end
    end
    api.register_route("POST", "/e2e/tool-assembly") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, _workspace, _about, body|
        assembled = client.tools.assemble(
          default_runner_executor_public_id: body.fetch("default_runner_executor_public_id"),
          configuration: body.fetch("configuration", selected)
        )
        [200, assembled.to_h]
      end
    end
    api.register_route("POST", "/e2e/tool-catalog") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, _workspace, _about, body|
        body.fetch("tool_definitions")
        selected = (selected || tool_sources(client)).merge(body.slice(*TOOL_FIELDS))
        documents = body["prompt_documents"]
        [200, { "configuration" => selected }]
      end
    end
    api.register_route("POST", "/e2e/tool-input") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, workspace_id, _about, body|
        workspace = client.workspace(workspace_id)
        public_id = body.fetch("public_id")
        hosted = workspace.conversation(public_id)
        conversation = hosted.fetch
        execution = ctx.conversation_execution(client, workspace, public_id, body: body, document: conversation)
        declaration = execution.fetch(:agent_configuration).merge(selected || {})
        declaration = declaration.merge(documents.slice("system_prompt", "summarizer")) if documents
        runner = conversation.default_runner&.executor_public_id
        tools = client.tools.assemble(default_runner_executor_public_id: runner,
          configuration: declaration.slice(*TOOL_FIELDS)).tool_definitions
        code_mode = Rho::CodeMode.enabled?(ctx.config, body.fetch("code_mode"))
        names = Rho::CodeMode.tools(tools, code_mode).map { |entry| entry.fetch("function").fetch("name") }
        names &= body.fetch("tool_names") if body.key?("tool_names")
        speaker = Rho::Speakers.owner(client: client, agent_public_id: ctx.own_user_public_id)
        lead = lead(ctx, public_id, runner: runner, model: execution.fetch(:model), code_mode: code_mode,
          working_directory: body["working_directory"])
        accepted = hosted.inputs.create(kind: "direct_reply", text: body.fetch("text"), delivery_mode: "queue",
          **execution.merge(agent_configuration: declaration), tool_names: names, speaker_public_id: speaker.public_id,
          executor_contexts: ctx.execution_contexts(client, tools: tools, runner: runner,
            host: public_id, workspace_public_id: workspace_id),
          inline: [{ "role" => "developer", "position" => "lead", "text" => lead }],
          idempotency_key: SecureRandom.uuid)
        [201, { "pending" => true, "conversation" => { "public_id" => public_id },
          "input" => { "public_id" => accepted.public_id } }]
      end
    end
  end

  def self.lead(ctx, public_id, runner:, model:, code_mode:, working_directory:)
    raise "diagnostic inputs require rho's own default Runner" unless ctx.own_runner?(runner)

    binding = ctx.environments.binding_for(public_id, runner: runner)
    environment = Rho::Env::Environment.local(root: binding&.root || ctx.tool_env.root, directories: binding ? binding.directories : [],
      working_directory: working_directory)
    ctx.environments.describing_lead(binding&.anchor) do
      Rho::RunDeclaration.lead(registry: ctx.registry, environment: environment, hints: ctx.lead_hints(model),
        code_mode: code_mode, kernel_environment: true, environment_snapshot: ctx.remote_runner(runner)&.environment_for(:runner),
        root: binding&.root, directories: binding ? binding.directories : [])
    end
  end

  def self.tool_sources(client)
    client.profile.fetch.configuration.to_h.transform_keys(&:to_s).slice(*TOOL_FIELDS)
  end

  def self.prompt_documents(client)
    client.profile.prompt_documents.list.to_h do |row|
      document = client.profile.prompt_documents.read(row.slot)
      [row.slot, { "content" => document.content, "role" => document.role }]
    end
  end
end
