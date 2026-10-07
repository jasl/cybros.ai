module NexusDoubles
  # The Agent API: /profile answers the member plane, /executor the transport
  # plane, and each refuses the other's credential exactly as Nexus does.
  class FakeAgentApi
    attr_reader :requests, :workspace_creates, :workspace_list_params, :workspace_fetches, :appends, :run_creates,
      :configuration_declarations, :prompt_document_writes, :prompt_document_deletes, :announcements, :runner_announcements,
      :run_inputs, :resolutions,
      :conversation_creates, :conversation_inputs, :compactions, :claims, :commits, :executor_inbox_reads,
      :adjudications,
      :runner_inbox_reads, :set_default_runners, :input_deletes, :input_updates, :forks, :conversation_deletes, :uploads,
      :context_estimates, :memory_writes, :regenerations, :variant_updates, :turn_windows,
      :named_agent_declarations, :named_agent_deletes, :store_entry_creates, :store_entry_updates, :tool_assemblies

    def initialize(user_public_id: "0199-user", executor_public_id: "0199-executor",
                   runner_executor_public_id: "0199-runner",
                   workspaces: [], workspace_create: :accept, inbox_tasks: [], runner_inbox_tasks: [],
                   claim: :accept, trace: nil, adjudication: nil, run_list: nil,
                   transcript: nil, task_detail: nil, graph: nil, phases: nil, append: nil,
                   task_request: nil, variants: nil, variant_request: nil,
                   tools: nil, configuration: :accept, announcement: :accept, prompt_document: :accept,
                   conversation_events: :materialized, conversation_event_head: nil, compaction: nil, commit: :accept,
                   executors: [], set_default_runner: :accept, conversation_input: :accept,
                   input_list: [], input_delete: :accept, input_update: :accept, fork: :accept,
                   conversation_list: [], context_estimate: nil, prompt_documents: [],
                   upload_bytes: {}, upload_representations: {}, upload_content_type: "image/png",
                   fork_runner_effects: nil, turns: nil, regeneration: nil, conversation_busy: nil,
                   conversation_runner: nil, models: [], model_providers: [],
                   named_agents: [], named_agent: :accept, principals: [], store_entry_update: :accept)
      @user_public_id = user_public_id
      # THE CONVERSATION'S STORE:
      # one row list per conversation, the kernel's rules — a singleton per
      # (namespace, key) (`key_taken`), the `lock_version` compare on PATCH
      # and DELETE (`stale_object`), summaries on the listing, the value on
      # the read. Every create and update recorded; `store_entry_update:`
      # is `:accept` or a Response that refuses every PATCH instead.
      @store_entries = Hash.new { |stores, conversation| stores[conversation] = [] }
      @store_entry_update = store_entry_update
      @store_entry_creates = []
      @store_entry_updates = []
      # The parent facts and the child listing a test stocks
      # for the environment's walk and the child edge.
      @parents = {}
      @children = Hash.new { |listings, parent| listings[parent] = [] }
      # THE NAMED DEFINITIONS DOOR:
      # the rows the listing holds — a test stocks a sibling's published
      # ones, `derived_from_public_id` not this profile's — and every PUT
      # body by name and every DELETE, recorded; a PUT mints or replaces
      # a row of this profile's (the handle the name, `-2` past a
      # collision; the same public id on a later PUT of the name, a
      # removed row restored as itself), 201 then 200. `named_agent:` is
      # `:accept`, a Response that refuses every PUT, or a CALLABLE
      # `(name, body) -> :accept | Response` refusing one file's.
      @named_agents = named_agents.map { |row| row.transform_keys(&:to_s) }
      @named_agent = named_agent
      @named_agent_declarations = []
      @named_agent_deletes = []
      @principals = principals
      # THE MODEL CATALOG: the rows `GET /models`
      # lists, stocked by a test that reads a model's facts (`rho adaptations`).
      @models = models
      # THE PROVIDER LANES: the rows `GET /model_providers` lists, stocked
      # by a test that reads them (`rho providers`).
      @model_providers = model_providers
      @executor_public_id = executor_public_id
      # THE RUNNER ADDRESS: the row the combined grant's runner
      # half names — its own inbox, its own announcement door, under the
      # runner's credential.
      @runner_executor_public_id = runner_executor_public_id
      @runner_announcements = []
      @runner_inbox_tasks = runner_inbox_tasks.map { |row| { "workspace_public_id" => "ws-1" }.merge(row) }
      @runner_inbox_reads = 0
      @requests = []
      # THE INGEST DOOR: every multipart part the daemon staged —
      # its filename and the bytes it read — answered with the scripted type.
      @uploads = []
      @upload_content_type = upload_content_type
      # THE BYTES READ: the bytes each public id streams back
      # into the caller's sink; an id not listed is the kernel's 404. THE
      # REPRESENTATION READS: `{ kind => { public_id => bytes } }`;
      # a listed upload with no entry of that kind is the kernel's typed
      # `representation_unavailable`.
      @upload_bytes = upload_bytes
      @upload_representations = upload_representations
      # The kernel tool catalog, stocked only by a test that fetches it (the
      # daemon fails open to none), and the declaration door: every body the
      # profile was declared with, or a Response that refuses instead.
      @tools = tools
      @configuration = configuration
      @configuration_declarations = []
      @tool_assemblies = []
      # Prompt effects from an accepted whole declaration or individual slot
      # write. A refused whole declaration records no prompt effect.
      @prompt_document = prompt_document
      @prompt_document_writes = []
      # The slots cleared by an accepted declaration or individual deletion.
      @prompt_document_deletes = []
      # THE PROFILE'S SLOTS AS READ (`rho prompt show`): the rows
      # the listing answers (text stripped) and a read answers whole.
      @prompt_documents = prompt_documents
      # THE TWO MEMORY DOORS: one store per
      # door — the profile's `user/` rung under "profile", a conversation's
      # three scopes under its id — as `{path => row}`, the kernel's
      # presenter shape with `description` (null on a plain document).
      # The writer's skill words are judged here as the kernel judges them,
      # so a verb's call_tool of a 422 is a fact a test can see.
      @memory = Hash.new { |stores, door| stores[door] = {} }
      @memory_writes = []
      # THE PREVIEW DOOR: every estimate body the daemon posted
      # (`{path:, body:}`), answered with the scripted document — the
      # rendered fixture — or a Response that refuses instead.
      @context_estimate = context_estimate
      @context_estimates = []
      # THE ANNOUNCEMENT DOOR: every body the executor plane
      # announced with, or a Response that refuses instead.
      @announcement = announcement
      @announcements = []
      # Scripted Workspace listing plus create behavior: :accept mints a row
      # and appends it to the listing; a Response overrides; an exception
      # raises (transport failures and the like). Rows carry the public
      # `dedicated:` projection, and the explicit current-Agent filter narrows
      # the result so tests prove Rho's adoption policy. Undedicated rows are
      # ordinary shared Workspace data, not authorization failures.
      @workspaces = workspaces
      @workspace_create = workspace_create
      @workspace_creates = []
      @workspace_list_params = []
      # THE ROOM KNOB's read: every `GET /workspaces/{id}`,
      # by id — the daemon fetches the room it was told instead of listing.
      @workspace_fetches = []
      # THE EXECUTOR INBOX: the rows addressed to this executor,
      # as the wire renders them; every claim by key and every commit's
      # envelope, recorded; `claim:` is `:accept` (the row's grant, and the
      # row reads `claimed` from then on) or `:taken` (409 already_claimed).
      @inbox_tasks = inbox_tasks.map { |row| { "workspace_public_id" => "ws-1" }.merge(row) }
      @claim = claim
      # `commit:` is `:accept` (recorded) or `:not_addressed_here` (409, the kernel's word for a row that is nobody's inbox row here — a Human-created run's ask).
      @commit = commit
      @claims = []
      @commits = []
      @executor_inbox_reads = 0
      # A scripted run trace, and a scripted answer (or refusal Response)
      # for the adjudication doors — enough to drive the repair verbs
      # without a kernel.
      @trace = trace
      @adjudication = adjudication
      # Every adjudication posted, as `[verb, key, body]` — `deny`'s reason
      # rides the body, and no reason is NO body.
      @adjudications = []
      @run_list = run_list
      @transcript = transcript
      @task_detail = task_detail
      @phases = phases
      # The picture, scripted whole: the route proxies it as the kernel drew it.
      @graph = graph
      # THE DEBUG DOOR: a round's sealed request, a turn's deck
      # and its active variant's sealed request — each scripted whole (or a
      # Response that refuses), proxied as the kernel answers them.
      @task_request = task_request
      @variants = variants
      @variant_request = variant_request
      # THE FOLLOWUP DOOR. A continuation is one append — close the
      # window, plant the round and the next window — so a test that
      # cannot see the ENVELOPE cannot check the gesture at all.
      @append = append
      @appends = []
      # THE CREATE DOOR: what `POST /runs` authored, byte for byte, and a
      # queued row minted for it so `start` and the follower have a run.
      @run_creates = []
      @minted_tasks = {}
      @workspace_sequence = 0
      # THE RUN DOOR: every input a host-typed verb posted, and
      # every await answered through the resolution door.
      @run_inputs = []
      @resolutions = []
      # THE CONVERSATION DOORS: what `rho do` created, every
      # `direct_reply` it posted, and the feed the follower reads — scripted
      # whole; `:materialized` narrates the first accepted input and its
      # matching turn. A test that wants the follower to wait hands an
      # empty list.
      @conversation_creates = []
      # The access carrier per conversation: what a create named or
      # a PUT replaced; the principals the listing answers, stocked by a test.
      @access = {}
      @answerers = {}
      @conversation_inputs = []
      @conversation_input_ids = {}
      # `conversation_input:` is `:accept` (recorded, 202) or a Response
      # that refuses instead — the kernel's own 422 on the input door.
      @conversation_input = conversation_input
      # THE QUEUE DOORS: the rows `GET …/inputs` lists, every id
      # `DELETE …/inputs/:id` dropped and every `[id, body]` `PATCH` rewrote;
      # `input_delete:`/`input_update:` are `:accept` or a Response that
      # refuses instead (the kernel's 409 on a kernel-origin row).
      @input_list = input_list
      @input_delete = input_delete
      @input_update = input_update
      @input_deletes = []
      @input_updates = []
      # THE SIDE DOORS: every fork body posted (a side names no turn),
      # each answered with a `side: true` child `c-N-side` beside the fork
      # point's `world` (`untouched` — nothing above it wrote); every conversation
      # DELETE; the rows `GET …/conversations?side=1` lists. `fork:` is
      # `:accept` or a Response that refuses instead.
      @fork = fork
      @forks = []
      @conversation_deletes = []
      @conversation_list = conversation_list
      @conversation_events = conversation_events
      @conversation_event_head = conversation_event_head
      # THE MANUAL COMPACTION DOOR: every body posted, and a scripted 202
      # (the mid-turn shape) in place of the idle summary turn.
      @compactions = []
      @compaction = compaction
      # DISCOVERY AND THE HANDOFF: the executors the acting
      # principal may address, as `GET /executors` lists them (the discovery
      # document whole — served_tools, environment, presence); every
      # set_default_runner `PUT …/runner` posted, keyed by host; and the binding each
      # host document reads back, written at create from the body's
      # `runner_executor_public_id` and rewritten by a set_default_runner. `set_default_runner:`
      # is `:accept` or a Response that refuses instead.
      # THE KERNEL'S OWN CEREMONY ON AN EXECUTOR ROW: `presence` is on every
      # row the presenter writes and the SDK reads it strictly, so a case
      # that scripts the fields it cares about still gets a row the real
      # client can parse (the same rule the task rows take).
      @executors = executors.map { |row| { "presence" => "offline" }.merge(row) }
      @set_default_runner = set_default_runner
      @set_default_runners = []
      # The binding a create names, by conversation; a create naming none
      # is unbound — the kernel infers no runner.
      @runner_bindings = {}
      # REWIND / REGENERATE: the fork point's `world` a fork
      # answers (default `untouched`), the turns a conversation lists
      # (`resolve_turn` and the tail check read them), the 202 a
      # regeneration answers, and a conversation's own busy/runner facts.
      @fork_runner_effects = fork_runner_effects
      @turns = turns
      @turn_windows = []
      @regeneration = regeneration
      @conversation_busy = conversation_busy
      @conversation_runner = conversation_runner
      @regenerations = []
      @variant_updates = []
    end

    # A binding stocked after the fact — a host this daemon follows whose
    # runner a Human moved through the SDK.
    def set_default_runner(host_public_id, executor_public_id)
      @runner_bindings[host_public_id] = executor_public_id
      nil
    end

    def stock_conversation(public_id, side: false)
      @conversation_list.reject! { |row| row.fetch("public_id") == public_id }
      @conversation_list << conversation_row(public_id, side: side)
    end

    # ---- the conversation's store ----

    # The rows as the kernel holds them now (values included), by conversation.
    def store_entries_of(conversation) = @store_entries[conversation].map(&:dup)

    # A row stocked before rho reads it — the kernel's fork copy, a
    # person's own write — at the version given.
    def stock_store_entry(conversation, namespace:, key:, value:, lock_version: 0)
      @store_entries[conversation] << store_entry_row(conversation, namespace, key, value, lock_version)
      nil
    end

    # A person's PATCH through the SDK between two turns: the value moves
    # and the version with it, behind rho's back.
    def patch_store_entry(conversation, namespace:, key:, value:)
      row = @store_entries[conversation].find { |candidate| candidate["namespace"] == namespace && candidate["key"] == key }
      row.merge!("value" => value, "lock_version" => row.fetch("lock_version") + 1)
      nil
    end

    # The parent a conversation's document names, and the
    # children a parent's listing answers.
    def stock_parent(child, parent)
      @parents[child] = parent
      nil
    end

    def stock_children(parent, rows)
      @children[parent] = rows
      nil
    end

    # A memory row stocked before a verb reads it, as a person's earlier
    # write left it: `door` is "profile" or a
    # conversation id.
    def stock_memory(door, path, content, description: nil)
      @memory[door][path] = memory_row(path, content, description)
      nil
    end

    # The principals the workspace listing answers: rows as the
    # kernel renders them, stocked by a test that needs a steward or a peer.
    def stock_principals(rows)
      @principals = rows
      nil
    end

    # The access carrier a conversation holds now, by public id — what a
    # create named or a PUT replaced, as the request spelled it.
    def access_of(public_id) = @access[public_id]

    # A runner's announcement moved after the fact — a repoint, its own or
    # another home's — as discovery would serve it from now on.
    def reannounce_executor(row)
      @executors = @executors.reject { |candidate| candidate.fetch("public_id") == row.fetch("public_id") } + [{ "presence" => "offline" }.merge(row)]
      nil
    end

    def call(path, method: :get, credential: nil, body: nil, form: nil, params: nil, headers: {}, timeout:, # rubocop:disable Lint/UnusedMethodArgument
             accept: nil, sink: nil)
      # Params too: a filter rides the query string, so a test that only
      # saw the path could not tell whether one was sent.
      @requests << [path, credential, params]
      return upload_bytes_response(path, sink) if sink

      response =
        case [method, path, credential]
        when [:get, "/agent_api/v1/profile", MEMBER_TOKEN] then respond(200, profile)
        when [:post, "/agent_api/v1/uploads", MEMBER_TOKEN] then upload_response(form)
        when [:put, "/agent_api/v1/profile/configuration", MEMBER_TOKEN]
          configuration_response(body)
        when [:put, "/agent_api/v1/profile/prompt_documents/system_prompt", MEMBER_TOKEN]
          prompt_document_response("system_prompt", body)
        when [:put, "/agent_api/v1/profile/prompt_documents/summarizer", MEMBER_TOKEN]
          prompt_document_response("summarizer", body)
        when [:delete, "/agent_api/v1/profile/prompt_documents/summarizer", MEMBER_TOKEN]
          prompt_document_delete_response("summarizer")
        when [:get, "/agent_api/v1/profile/prompt_documents", MEMBER_TOKEN]
          respond(200, { "prompt_documents" => @prompt_documents.map { |row| row.except("content") } })
        when [:get, "/agent_api/v1/profile/agents", MEMBER_TOKEN] then named_agents_listing
        when [:post, "/agent_api/v1/tools/assembly", MEMBER_TOKEN] then tool_assembly_response(body)
        when [:get, "/agent_api/v1/tools", MEMBER_TOKEN]
          @tools ? respond(200, { "tools" => @tools }) : respond(401, unauthorized)
        when [:get, "/agent_api/v1/models", MEMBER_TOKEN] then respond(200, { "models" => @models })
        when [:get, "/agent_api/v1/model_providers", MEMBER_TOKEN]
          respond(200, { "model_providers" => @model_providers })
        when [:get, "/agent_api/v1/executors", MEMBER_TOKEN]
          kind = params && params["kind"]
          respond(200, { "executors" => @executors.select { |row| kind.nil? || row.fetch("kind") == kind } })
        when [:get, "/agent_api/v1/executor", TRANSPORT_TOKEN] then respond(200, executor)
        when [:get, "/agent_api/v1/executor", RUNNER_TOKEN] then respond(200, runner_executor)
        when [:put, "/agent_api/v1/executor/announcement", TRANSPORT_TOKEN]
          announcement_response(body)
        when [:put, "/agent_api/v1/executor/announcement", RUNNER_TOKEN]
          runner_announcement_response(body)
        when [:get, "/agent_api/v1/executor/inbox", TRANSPORT_TOKEN] then inbox_response
        when [:get, "/agent_api/v1/executor/inbox", RUNNER_TOKEN] then runner_inbox_response
        when [:get, "/agent_api/v1/workspaces", MEMBER_TOKEN] then respond(200, workspace_list(params))
        when [:post, "/agent_api/v1/workspaces", MEMBER_TOKEN]
          workspace_create_response(body, headers)
        else
          named_agent_response(method, path, credential, body) ||
          workspace_fetch_response(method, path, credential) ||
          prompt_document_read_response(method, path, credential) ||
          memory_response(method, path, credential, body) ||
          executor_response(method, path, credential) ||
            inbox_task_response(method, path, credential, body) ||
            principals_response(method, path, credential) ||
            conversation_response(method, path, credential, body, params: params) ||
            run_response(method, path, credential, body) ||
            respond(401, { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } })
        end
      raise response if response.is_a?(Exception)

      response
    end

    # A row stocked after boot, so a test can make the cable — not the
    # first sweep — the claimant. `address:` names whose inbox: the agent
    # address's (the transport credential's) or the runner's.
    def stock_inbox(row, address: :agent)
      (address == :runner ? @runner_inbox_tasks : @inbox_tasks) << { "workspace_public_id" => "ws-1" }.merge(row)
      nil
    end

    # THE RUNNER'S INBOX on the executor plane, empty unless a test stocks
    # it. The daemon starts a runner the moment a workspace is adopted, so
    # every connected-daemon test polls this — answering 401 would stop the
    # runner in every one of them (a 401 here is terminal) to prove nothing.
    def inbox_response
      @executor_inbox_reads += 1
      respond(200, { "tasks" => @inbox_tasks, "pagination" => { "next_after" => nil } })
    end

    def runner_inbox_response
      @runner_inbox_reads += 1
      respond(200, { "tasks" => @runner_inbox_tasks, "pagination" => { "next_after" => nil } })
    end

    # ---- the named definitions door ----

    # The rows as the kernel lists them: active rows minted by this
    # profile (both scopes) plus the stocked published rows of others.
    def named_agents_listing
      rows = @named_agents.reject { |row| row["status"] == "removed" }.sort_by { |row| row["display_name"] }
      respond(200, { "agents" => rows.map { |row| row.except("status") } })
    end

    def named_agent_response(method, path, credential, body)
      name = path[%r{\A/agent_api/v1/profile/agents/([^/]+)\z}, 1]
      return nil unless name && credential == MEMBER_TOKEN

      case method
      when :put then named_agent_put(name, body)
      when :delete then named_agent_delete(name)
      else nil
      end
    end

    def named_agent_put(name, body)
      @named_agent_declarations << [name, body]
      answer = @named_agent.respond_to?(:call) ? @named_agent.call(name, body) : @named_agent
      return answer unless answer == :accept

      found = own_named_agent(name)
      row = (found || mint_named_agent(name)).merge(
        "status" => "active", "scope" => body.fetch("scope"), "description" => body.fetch("description"),
        "display_name" => body["display_name"] || name, "system_prompt" => body["system_prompt"],
        "configuration" => body.fetch("configuration")
      )
      @named_agents = @named_agents.map { |candidate| candidate["public_id"] == row["public_id"] ? row : candidate }
      @named_agents << row if found.nil?
      respond(found ? 200 : 201, { "agent" => row.except("status", "system_prompt") })
    end

    def named_agent_delete(name)
      @named_agent_deletes << name
      row = own_named_agent(name)
      if row.nil? || row["status"] == "removed"
        return respond(404, { "error" => { "code" => "not_found", "message" => "No active definition named #{name}" } })
      end

      @named_agents = @named_agents.map { |candidate| candidate.equal?(row) ? row.merge("status" => "removed") : candidate }
      respond(204, nil)
    end

    def own_named_agent(name)
      @named_agents.find { |row| row["name"] == name && row["derived_from_public_id"] == @user_public_id }
    end

    # The kernel's handle pick for a named row: the name, else `-2`, `-3`.
    def mint_named_agent(name)
      taken = @named_agents.map { |row| row["handle"] }
      handle = name
      suffix = 1
      handle = "#{name}-#{suffix += 1}" while taken.include?(handle)
      { "public_id" => "na-#{@named_agents.length + 1}", "handle" => handle, "kind" => "agent", "name" => name,
        "agent_identifier" => "rho.fake/#{name}", "steward_public_id" => "0199-steward",
        "derived_from_public_id" => @user_public_id }
    end

    # THE PRINCIPALS LISTING: the rows a test stocked, as the kernel
    # renders them, under the member credential alone.
    def principals_response(method, path, credential)
      return nil unless method == :get && credential == MEMBER_TOKEN &&
        path.match?(%r{\A/agent_api/v1/workspaces/[^/]+/principals\z})

      respond(200, { "principals" => @principals })
    end

    # THE CLAIM AND THE COMMIT, under a transport credential —
    # the agent address's or the runner's, each on its own rows: a claim
    # answers the executable row and a token, and marks the row claimed so
    # the sweep leaves it; a commit records the flat envelope.
    def inbox_task_response(method, path, credential, body)
      return nil unless method == :post && [TRANSPORT_TOKEN, RUNNER_TOKEN].include?(credential)

      run_id, key, verb = path.match(%r{\A#{EXECUTOR_PLANE}/inbox/([^/]+)/([^/]+)/(claim|commit)\z})&.captures
      return nil if verb.nil?

      if verb == "commit" && @commit == :not_addressed_here
        return respond(409, { "error" => { "code" => "not_addressed_here", "message" => "not your row" } })
      end

      rows = credential == RUNNER_TOKEN ? @runner_inbox_tasks : @inbox_tasks
      row = rows.find do |candidate|
        candidate.fetch("run_public_id") == run_id && candidate.fetch("task_key") == key
      end
      return respond(404, { "error" => { "code" => "not_found", "message" => "no such row" } }) if row.nil?

      verb == "claim" ? claim_response(row, credential) : commit_response(key, body)
    end
  end
end
