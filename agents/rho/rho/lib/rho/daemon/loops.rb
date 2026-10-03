require "async/semaphore"
require_relative "loops/bindings"
require_relative "loops/policies"
require_relative "loops/named_definitions"
require_relative "loops/sides"
require_relative "loops/authoring"
require_relative "loops/following"
require_relative "loops/materialization"

module Rho
  class Daemon
    # The SDK-wrapping verbs: a conversation opened with the tools of the runner it is bound
    # to and followed on its feed, a followed host spoken to and stopped,
    # plus the store a restarted daemon re-follows from. The standalone-loop
    # author and the followed-set reads are the Ops extension's; the
    # binding's reading — which runner, whose lead, whose names — is
    # `Bindings`.
    class Loops
      include Bindings
      include Policies
      include NamedDefinitions
      include Sides
      include Authoring
      include Following
      include Materialization

      DELIVERY_MODES = %w[steer queue].freeze
      # The kernel's two "not before" spellings.
      SCHEDULE_FIELDS = %w[deliver_at deliver_in].freeze
      # Materialization is asynchronous (`DrainJob`): the daemon follows its
      # own input on the conversation feed until a `turn_status` carries the
      # backing loop, bounded — and answers `pending` past the bound rather
      # than holding the terminal. An input the kernel BLOCKS on the way
      # (`input_blocked` with a durable reason) is a refusal the moment it
      # lands, never a wait.
      MATERIALIZATION_WAIT = 30
      MATERIALIZATION_POLL = 1.0

      # What `:turn_author` sees and answers: the request, the environment
      # the tools are bound to, the ONE inline entry the turn opens with —
      # the developer-role lead (`lead`, which an extension may extend; behind history, outside the stable prefix), `notes` — one Hash
      # per extension, remembered with the host and handed to `:turn_follow`
      # — and `tools`, the turn's own surface: the declaration as the tier
      # narrows it, which a seed copying round one must carry byte for byte.
      Draft = Data.define(:body, :environment, :lead, :notes, :tools)

      # THE PICTURES A VERB BROUGHT: the ids the daemon
      # staged on its member plane — under rho's own user, so the kernel's
      # creator-scoped bind finds them — and the descriptors the kernel
      # answered, for the terminal's `attached:` lines.
      Staged = Data.define(:ids, :descriptors) do
        def self.none = new(ids: [], descriptors: [])
        def any? = ids.any?
      end

      # THE TIER ONE TURN RUNS IN, resolved once — in `open` from the flag, in `say` from the
      # row — and never again for the conversation's life (a mid-conversation flip splits the model's cache): the compose decision,
      # the declared bytes it keeps, and the subset the input names (nil
      # runs the whole declaration). No style words: the VIEW is the whole
      # declaration under one adaptation row per boot — the compose narrowing is the one `tool_names` writer.
      Tier = Data.define(:compose, :tools, :tool_names)

      # THE KERNEL'S CATALOG AS FETCHED: the definitions the settings name
      # (`kernel_tools`, in order) and every served tool's macro-bearing
      # `template` by canonical — what a pack row's `recut` renders against.
      Catalog = Data.define(:definitions, :templates) do
        def self.none = new(definitions: [], templates: {})
      end

      # THE DECLARATION'S REFUSAL: what `declare`
      # answers when the kernel refused the profile write — its code — or
      # the boot row's anchor moved (`anchor_moved`); beside `:declared`
      # and `:unchanged`, so a grant's route can revoke what did not land.
      Refused = Data.define(:code)

      # The kernel's vocabulary for a turn's `approval_mode`, nil for "the
      # profile's word".
      APPROVAL_MODES = [nil, "bypass", "ask", "rules"].freeze
      # The kernel's access levels; nil is the kernel's own default.
      ACCESS_DEFAULTS = [nil, "full", "read", "none"].freeze

      # `on_host_ended` is told each host this daemon stops following, or whose tools left
      # this machine's runner: the daemon releases the processes that host's loops started.
      # `environments` is the daemon's environment tables: the record written at the open,
      # read at every lead, relayed to a runner elsewhere, copied top-down at the child edge.
      def initialize(lineage:, home:, config:, wire:, loaded:, log:, context:, environments:,
                     clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) }, on_host_ended: nil)
        @lineage = lineage
        @home = home
        @config = config
        @wire = wire
        @loaded = loaded
        @log = log
        @context = context
        @environments = environments
        @clock = clock
        @sleeper = sleeper
        @on_host_ended = on_host_ended
        # THE PACK AND THE KNOB, loaded at boot and on settings changes: a
        # pinned row that no file carries, or a malformed local row, refuses
        # the boot by name here, never a silent `default`.
        @adaptations = Rho::Adaptations.load(config, home: home)
        # THE SESSION GRANTS and the one declaring GATE (`Bindings`): born empty every boot — the session is until the
        # daemon's next boot — and every declaration runs under the gate.
        # A REACTOR GATE, NOT A THREAD LOCK: every declarer is a fiber of
        # the control server's reactor (the boot's spawned declaration,
        # the routes, the stop edge spawned there too), the daemon tree's
        # one thread lock is Lineage's monitor (the lock ranking,
        # `lineage_lock_test`), and a waiting fiber parks on the reactor
        # — the SDK's own idiom for a serialized section under Async
        # (`Realtime::Client`).
        @grants = [].freeze
        # A Semaphore lets daemon fibers wait without blocking the reactor thread; lineage_lock_test pins that behavior.
        @declaring = Async::Semaphore.new(1)
      end

      # rho's policy over the SDK's model-adaptations pack, for the verbs
      # and the status document.
      attr_reader :adaptations

      # Settings replace the declaration for future turns. Followed hosts,
      # grants and already frozen Nexus loops retain their existing state.
      def configure(config:, loaded: @loaded)
        adaptations = Rho::Adaptations.load(config, home: @home)
        @declaring.acquire do
          @config = config
          @loaded = loaded
          @adaptations = adaptations
          @kernel_catalog = nil
          @context.member_plane(require_workspace: false) { |client, *| declare_locked(client) }
        end
      end

      # The turn row's `lead_hints` for a model — the per-request lines the
      # four leads carry; none under `off`.
      def lead_hints(model) = @adaptations.for(model).hint_texts

      # The core's routes: the author and the three host-typed verbs keyed
      # by a followed host id (never by a host kind) — through the same
      # door every extension uses.
      def register(api)
        api.register_route("POST", "/conversations") { |request, ctx| open(request, ctx) }
        api.register_route("POST", "/say") { |request, ctx| say(request, ctx) }
        api.register_route("POST", "/stop") { |request, ctx| stop(request, ctx) }
        api.register_route("POST", "/compact") { |request, ctx| compact(request, ctx) }
        # The side conversation: the core's, because the store is the
        # core's — `rho btw` and `rho side` are the Ops extension's verbs over it.
        api.register_route("POST", "/side") { |request, ctx| side(request, ctx) }
        # THE KERNEL'S FACTS FOR A MODEL: what `rho
        # adaptations` prints under `facts:` when a daemon is up — read off
        # `GET /models` through the member plane; the row itself the CLI
        # resolves from the files alone.
        api.register_route("GET", "/adaptations") { |request, ctx| model_facts(request, ctx) }
        # THE ACCOUNT'S PROVIDER LANES (the provider admission floor): what `rho providers` prints — the lanes as the kernel
        # holds them, each with its `unavailable_until` when the provider's
        # `Retry-After` floor stands. Read off the member plane; no arithmetic.
        api.register_route("GET", "/providers") { |request, ctx| providers(request, ctx) }
      end

      # One row per lane, the kernel's own words: the ISO string rides as
      # sent (nil when clear), so the terminal shows the provider's clock
      # and never this daemon's reading of it.
      def providers(request, ctx)
        ctx.member_plane(request, require_workspace: false) do |client, *|
          rows = client.model_providers.list.map do |lane|
            {
              id: lane.id, credentials: lane.credentials, enabled: lane.enabled?, configured: lane.configured?,
              reauthorization_required: lane.reauthorization_required, models: lane.models,
              unavailable_until: lane.unavailable_until,
            }
          end
          [200, { providers: rows }]
        end
      end

      # `facts: (no daemon)` is the CLI's own line; here a daemon answers
      # the available model's fact (`default_model` when none),
      # or `known: false` when it is unavailable or unknown. A model
      # without its lane segment is refused as a missing one is: the pack
      # cannot resolve it (`CybrosAgent::ModelPattern.reference`).
      def model_facts(request, ctx)
        model = ControlServer.query(request)["model"].to_s
        model = @config.default_model.to_s if model.empty?
        return Refusal.malformed("model is required, as provider/reference") unless model.include?("/")

        ctx.member_plane(request, require_workspace: false) do |client, *|
          row = client.models.list.find { |entry| entry.ref == model }
          facts = row.nil? ? { known: false } : { known: true, tool_calls: row.tool_calls? }
          [200, { model: model, adaptations: @adaptations.facts(model), facts: facts }]
        end
      end

      # `rho do`: a conversation, then one `direct_reply` input the kernel
      # materializes into a loop-backed turn. The model is the flag's, else
      # the settings' `default_model`; neither is refused here, where the
      # settings are — the CLI cannot read them. The compose tier is the
      # flag's (`compose: true|false`), else the settings' ladder. The
      # RUNNER the turn's tools run on is `Context#runner_selection`'s,
      # read BEFORE the turn is rendered: own or none
      # keeps the local bytes; another renders its snapshot and narrows the
      # names. Every environment field is optional and constrains nothing
      # — the tools decline path confinement — and a remote runner's
      # Draft carries none: its tools run where the runner is.
      def open(request, ctx)
        ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
          prompt = body["prompt"].to_s
          next open_promptless(client, workspace_public_id, body, ctx) if prompt.empty? && !attachments_present?(body)

          model = body["model"].to_s
          model = @config.default_model.to_s if model.empty?
          next Refusal.malformed("model is required, as provider/reference") if model.empty?

          compose = body["compose"]
          next Refusal.malformed("compose must be true or false") unless [true, false, nil].include?(compose)

          # THE TURN'S TIGHTENING: the input's `approval_mode`
          # in the kernel's own vocabulary — `bypass` is rank-equal and
          # lawful, the flag simply does not offer it; the kernel refuses
          # `not_tightening` itself, relayed as its 422 sentence.
          unless APPROVAL_MODES.include?(body["approval_mode"])
            next Refusal.malformed("approval_mode must be bypass, ask or rules")
          end

          # THE ACCESS DEFAULT: `rho do --restricted` sends `none`;
          # absent is the kernel's `full`. The steward's entry is added at
          # the create, from the principals listing.
          unless ACCESS_DEFAULTS.include?(body["access_default"])
            next Refusal.malformed("access_default must be full, read or none")
          end

          # THE ANSWERER: `rho do --agent IDENT` names who
          # answers, resolved through the principals listing; absent, the
          # kernel's default — rho itself.
          answerer = body.key?("agent") ? resolve_answerer(client, workspace_public_id, body["agent"]) : nil
          next answerer if answerer in Refusal

          staged = input_attachments(client, body, ctx)
          next staged if staged in Refusal

          # THE ROOT SET: validated BEFORE the create; the lead
          # renders from the validated body, the record is written after.
          runner = ctx.runner_selection(body)
          root_set = root_set_of(body, runner)
          next root_set if root_set in Refusal

          surface = turn_surface(client, runner, model: model, working_directory: body["working_directory"],
            instructions: body["instructions"], binding: root_set)
          tier = tier_for(client, model: model, compose: compose, surface: surface)
          # The draft carries the IDS where the verb sent paths: the reply
          # input names uploads, never files.
          draft = author_hooks(
            Draft.new(body: body.merge("prompt" => prompt, "model" => model, "attachments" => staged.ids), environment: surface.environment,
              lead: surface.lead, notes: {}, tools: tier.tools),
            ctx
          )
          next draft if draft in Refusal

          open_conversation(client, workspace_public_id, draft, tier, ctx, runner: runner, surface: surface,
            answerer: answerer, staged: staged, root_set: root_set)
        end
      end

      # ONE verb, host-typed: the host picks the kind its door
      # admits — a `message` on a standalone loop, a `direct_reply` on a
      # conversation, on the model `say_model` resolves (the row's own, else the settings' `default_model`, else the addressed turn's off the loop projection; a refusal only when the wire carries none either) and in the compose tier it was opened in (the row's; a row
      # from before the switch follows the settings) — and `delivery_mode` says whether the words
      # land at the running turn's next boundary (`steer`, the default;
      # idle, it simply queues and starts) or wait for the turn boundary
      # (`queue`). A host whose follow ended (a restart) is followed again
      # first, so the next turn has a watcher. THE BINDING IS READ HERE TOO:
      # the turn's names are narrowed to the row's runner, and
      # when that runner is not the one the last lead named — a handoff
      # landed since, this daemon's or a Human's through the SDK — the lead
      # is rendered again for it, once, inline through the same door the
      # open used (rho sends it every turn; the kernel lays it once per
      # window); the running turn keeps its bytes. A standalone loop's
      # seed is fixed: its lead is never re-rendered. `to` (`rho say --to IDENT`) names WHO ANSWERS this one turn, resolved
      # over the principals listing as `--agent` is and sent as the door's
      # addressee; the bare decision follows the ADDRESSEE, never the row:
      # a turn for another profile carries the words
      # alone, a turn for rho itself its tier's names — and, on a row
      # another profile answers by default, the lead the bare open
      # withheld, once. A loop has one answerer and refuses the word.
      def say(request, ctx)
        host_command(request, ctx) do |host, hosted, row, body, workspace, client|
          text = body["text"].to_s
          next Refusal.malformed("text or attachments are required") if text.strip.empty? && !attachments_present?(body)

          mode = body.fetch("delivery_mode", "steer").to_s
          next Refusal.malformed("delivery_mode must be steer or queue") unless DELIVERY_MODES.include?(mode)
          next Refusal.malformed("wait must be true or false") unless [true, false].include?(body.fetch("wait", true))
          next Refusal.malformed("kind must be direct_reply or message") unless [nil, "direct_reply", "message"].include?(body["kind"])
          if body["kind"] == "message"
            next say_message(host, hosted, row, body, workspace, client, ctx, text, mode)
          end
          inline = body.key?("inline") ? Array.try_convert(body["inline"]) : []
          next Refusal.malformed("inline must be a list") if inline.nil?
          # THE KERNEL'S WORD, before a byte is staged: a steer
          # takes no picture this slice; the verb's `--attach` queues.
          if mode == "steer" && attachments_present?(body)
            next Refusal.new(status: 422, code: "attachments_not_steerable",
              message: "A picture rides a queued turn, never a steer: say it with --mode queue")
          end

          # NOT BEFORE A TIME: the
          # kernel's two fields pass through as typed — the daemon parses
          # neither; a loop's one turn is in flight from create to
          # terminal, so nothing on it can wait, refused before the call.
          schedule = SCHEDULE_FIELDS.to_h { |key| [key.to_sym, body[key]] }.compact
          next Refusal.malformed("deliver_at and deliver_in are strings") unless schedule.values.all?(String)
          next Refusal.malformed("a loop's one turn is in flight: nothing waits behind it — drop --at/--in") if
            schedule.any? && !host.outlives_turn?

          addressee = body.key?("to") ? resolve_answerer(client, row.workspace, body["to"]) : nil
          next addressee if addressee in Refusal
          next Refusal.malformed("a loop has one answerer: `to` names who answers a conversation's turn") if
            addressee && !host.outlives_turn?

          # THE TURN'S TWO FIELDS: the
          # body's model rides ahead of the row's and the settings' — an
          # editor's picker, a `--model` — and the tightening in the
          # kernel's vocabulary, refused by name outside it.
          unless APPROVAL_MODES.include?(body["approval_mode"])
            next Refusal.malformed("approval_mode must be bypass, ask or rules")
          end
          next Refusal.malformed("a loop's one turn is in flight: no model, no approval_mode, no tool_names") if
            !host.outlives_turn? && %w[model approval_mode tool_names].any? { |key| body.key?(key) }

          readopt_row(row, host, hosted, workspace, ctx) if @lineage.run(host.public_id).nil?
          named = body["model"].to_s
          model =
            if !host.outlives_turn? then row.model
            elsif named.empty? then say_model(row, workspace)
            else named
            end
          next Refusal.malformed(MODEL_REQUIRED_ON_SAY) if host.outlives_turn? && model.nil?

          # A SIDE ROW takes its posture's subset and the tail on every
          # turn, and never a lead — it is rho's own, so no `to`; a turn
          # ANSWERED BY ANOTHER PROFILE (the addressee named here, else the row's remembered answerer) takes the bare words —
          # the names and the lead are rho's declaration's, not the
          # addressee's; a plain turn takes the tier's names.
          side = side_row?(row)
          # THE READ EDGE: the record read at the
          # lead render — the memo is this turn's; a person's SDK edit
          # between two says reaches this lead. A side renders no lead.
          plane = Extensions::MemberPlane.new(client: client, workspace_public_id: row.workspace)
          record = (@environments.read(host.public_id, plane: plane) if host.outlives_turn? && !side)
          surface = turn_surface(client, row.runner, model: model, binding: record&.binding)
          tier = tier_for(client, model: model, compose: row.compose, surface: surface)
          next Refusal.malformed("a side conversation is rho's own: no `to`") if addressee && side
          next Refusal.malformed("a side conversation's tightening is its posture's: no `approval_mode`") if
            side && body.key?("approval_mode")

          bare = addressee ? addressee.public_id != ctx.own_user_public_id : row.foreign?
          staged = input_attachments(client, body, ctx)
          next staged if staged in Refusal

          fields = say_fields(host, row, text, mode: mode, tier: tier, side: side, bare: bare, to: addressee&.public_id,
            attachments: staged.ids, model: model, schedule: schedule, approval_mode: body["approval_mode"], tool_names: body["tool_names"])
          next fields if fields in Refusal

          fields[:speaker_actor_public_id] = body["speaker_actor_public_id"] if body.key?("speaker_actor_public_id")
          if body.key?("expected_steering_loop_public_id")
            fields[:expected_steering_loop_public_id] = body["expected_steering_loop_public_id"]
          end
          # THE LEAD RIDES EVERY TURN (rendered live per request), as the developer-role lead
          # `reply_fields` sends; the kernel LAYS it once per window. It places a lead behind
          # history as its turn's preface and replays it there on later turns, and a lead equal to
          # the one the window already carries is not laid again — so an unchanged environment
          # costs one copy, and a moved one appends a new one rather than editing the prefix. It
          # still rides every turn: a compaction summary or a trimmed history can drop the turn
          # that carried the last one, and only the kernel knows what is in the window. The runner's
          # environment is per-request text, never the slot's. Rendered from this turn's read
          # (the record above, the binding's port): a moved record reaches the next lead by
          # construction. Absent only when empty (a runner discovery cannot show), which the
          # kernel would refuse as an empty entry.
          if !side && !bare && host.outlives_turn? && !surface.lead.empty?
            fields = fields.merge(inline: [{ "role" => "developer", "position" => "lead", "text" => surface.lead }])
          end
          # Caller context follows the existing surface/side preface; neither
          # replaces the other. Nexus owns inline entry validation and placement.
          fields[:inline] = fields.fetch(:inline, []) + inline unless inline.empty?
          # A turn for a runner elsewhere is never sent before its names are
          # declared (the same line `open` holds): whoever moved the row
          # declared, and the digest makes this a no-op when the union
          # already carries it — kept as the guard it is, harmless when
          # redundant (the kernel infers no binding).
          declare(client) if surface.remote?
          # THE RUNNER ELSEWHERE IS TOLD after the turn's read:
          # relayed when the tuple or the runner's boot moved, never when
          # both match — one discovery read per turn on a remote-runner row.
          relayed = (@environments.assert_remote(host.public_id, row.runner, record.binding, plane: plane) if surface.remote? && record&.binding)
          # Anchor before posting: the receipt follows this input, even
          # when another queued sender materializes first.
          run = @lineage.run(host.public_id)
          position = run&.event_position || CybrosAgent::KernelFeed::Position.start
          in_flight = turn_in_flight?(run)
          save_policy(host, hosted, model: model) if host.outlives_turn? && model != row.model
          accepted = hosted.inputs.create(**fields, idempotency_key: body["idempotency_key"] || SecureRandom.uuid)
          touch_side(host, row, hosted) if side
          # What the turn rode is the row's from here, as an opened row's is.
          remember(host, workspace: row.workspace, live: row.live, model: model) if model != row.model
          answer = { input: input_receipt(accepted, position), runner: runner_answer(row) }
          answer[:addressed_to] = { public_id: addressee.public_id, handle: addressee.handle } if addressee
          answer[:attachments] = staged.descriptors if staged.descriptors.any?
          if record&.binding
            answer[:environment] = { root: record.root, directories: record.directories, relayed: relayed&.to_h }.compact
          end
          next [200, answer] unless host.outlives_turn?
          next [200, answer.merge(pending: true)] if body["wait"] == false

          turn = turn_answer(hosted, accepted, position, in_flight: in_flight)
          # A PARKED ROW answers as the kernel now holds it: the state
          # word and the reason on the input, beside the top-level `blocked`.
          if turn.key?(:blocked)
            answer = answer.merge(input: answer[:input].merge(state: "blocked", blocked_reason: turn[:blocked]))
          end
          [200, answer.merge(turn)]
        end
      end

      # `force` defaults to true because a person typing `rho stop` means
      # now; a conversation's stop is its cancellation, which takes no force.
      # With a `task_key` ONE branch is canceled on the loop the id names —
      # a conversation's current backing loop through the store row — and the turn runs on.
      # Explicit host_type bypasses the followed-set resolver: an old loop
      # remains an exact loop even after its conversation advances. Without
      # a type only a remembered host can be addressed; never guess an unknown id.
      def stop(request, ctx)
        ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
          public_id = body["public_id"].to_s
          next Refusal.malformed("public_id is required") if public_id.empty?

          workspace = client.workspace(workspace_public_id)
          row = store.find(public_id)
          host_type = body["host_type"]
          unless host_type.nil? || Host::TYPES.key?(host_type)
            next Refusal.malformed("host_type must be agent_loop or conversation")
          end
          if host_type.nil? && row.nil?
            next Refusal.not_followed(public_id, lane: :host, hint: "name host_type as conversation or agent_loop")
          end

          host = host_type ? Host.from(host_type, public_id) : row.host
          stop_followed(host, host.context(workspace), row, body, workspace)
        end
      end

      def stop_followed(host, hosted, row, body, workspace)
        task_key = body["task_key"].to_s
        if task_key.empty?
          status = host.stop(hosted, force: body.key?("force") ? body["force"] == true : true)
          stopped = { host_type: host.type, public_id: host.public_id, status: status }
          stopped[:followed] = false if row.nil?
          return [200, { stopped: stopped }]
        end

        if row.nil? && host.own_loop.nil?
          return Refusal.not_followed(host.public_id, lane: :host, hint: "attach it first, or name the exact agent_loop")
        end

        loop_public_id = host.own_loop || row.loop
        return Refusal.malformed("#{host.public_id} has no turn in flight to cancel a task on") if loop_public_id.nil?

        task = workspace.agent_loops.agent_loop(loop_public_id).tasks_context(task_key).cancel
        [200, { stopped: { host_type: "task", public_id: task.key, status: task.status,
                           loop: loop_public_id } }]
      end

      # ONE verb, host-typed: a conversation's door compacts
      # its running loop-backed reply on the spine's next round, or its
      # history when idle — the kernel picks the round, so a key is
      # refused; a standalone loop's door compacts the round the key
      # names, and the key is required (the retry/abandon chooser reads
      # failures; a compaction has none to read).
      def compact(request, ctx)
        host_command(request, ctx) do |host, hosted, _row, body|
          task_key = body["task_key"].to_s
          refusal = host.compact_refusal(task_key)
          next Refusal.malformed(refusal) if refusal

          [200, { compacted: host.compact(hosted, task_key: task_key) }]
        end
      end

      # Every followed host is remembered, not only the gated ones: a
      # restarted daemon must follow them all again, or work advances with
      # nobody watching. A conversation's row carries its current turn, the
      # loop backing it, the model it last replied on, and the runner its
      # calls land on.
      def remember(host, workspace:, live: true, notes: nil, turn: HostStore::KEEP, loop: HostStore::KEEP, model: nil, compose: nil,
                   runner: HostStore::KEEP, answerer: HostStore::KEEP)
        evicted = store.remember(host, workspace: workspace, live: live, notes: notes,
          turn: turn, loop: loop, model: model, compose: compose, runner: runner, answerer: answerer)
        @log.info("loops.forgotten_to_stay_bounded", hosts: evicted) if evicted&.any?
      rescue Rho::StateError => error
        @log.warn("loops.remember_failed", host: host.public_id, detail: error.message)
      end

      # A host this daemon no longer follows has ended HERE: its store row goes, and so do the
      # processes its loops started. A naturally settled standalone loop retains its final
      # snapshot for local readers, with no open subscriptions or restart record.
      def forget(host, retain_snapshot: false)
        store.forget(host)
      rescue Rho::StateError => error
        @log.warn("loops.forget_failed", host: host.public_id, detail: error.message)
      ensure
        run = retain_snapshot ? @lineage.run(host.public_id) : @lineage.drop_run(host.public_id)
        run&.stop
        host_ended(host)
      end

      def host_ended(host)
        @on_host_ended&.call(host)
      rescue StandardError => error
        @log.warn("loops.host_ended_failed", host: host.public_id, error_class: error.class.name)
      end

      # What the extensions recorded about a host this daemon remembers;
      # empty for one it does not.
      def notes(public_id)
        store.find(public_id)&.notes || {}
      rescue Rho::StateError => error
        @log.warn("loops.notes_read_failed", host: public_id, detail: error.message)
        {}
      end

      # THE DAEMON'S CURRENT CONVERSATION (`rho skills --scope workspace` with no `--conversation`): the newest followed
      # conversation that is not a side — the same row `rho btw` asks
      # beside; nil when this daemon follows none.
      def current_conversation_public_id
        newest_conversation&.host_public_id
      rescue Rho::StateError
        nil
      end

      # The loop a loop-grain verb acts on: a conversation id names the
      # loop backing its current turn; a loop id is its own answer.
      def backing_loop(public_id)
        row = store.find(public_id)
        return public_id if row.nil? || row.host_public_id != public_id

        row.loop || public_id
      rescue Rho::StateError
        public_id
      end

      # THE MODEL A SEND ON THIS CONVERSATION RIDES when none is named:
      # `say_model` for a row this daemon follows, and the settings'
      # `default_model` alone for one it does not, which has no row to
      # remember a model and no loop to read a turn's model from. The
      # prompt preview reads it so it compiles what the send would seal.
      def conversation_model(public_id, workspace)
        row = store.find(public_id)
        row = hydrate_policy(row, row.host.context(workspace)) if row&.host&.outlives_turn?
        row ? say_model(row, workspace) : @config.default_model
      end

      # The run a host id — or a loop backing a followed conversation's
      # turn, the current one or an EARLIER turn's — names; nil for one
      # nobody here follows. The store row carries only the current loop;
      # the follower saw every one (`loops`), which is the rule `rho watch`
      # reads rows by, and `rho follow`/`subscribe` given an earlier turn's
      # id answered 404 until this lookup read that history too.
      def followed(public_id)
        row = store.find(public_id)
        @lineage.run(row ? row.host_public_id : public_id) || backed_by(public_id)
      rescue Rho::StateError
        @lineage.run(public_id) || backed_by(public_id)
      end

      # The one resolution rule for a follower verb given a LOOP id: the store's row first, else the loop's own turn block.
      def host_of(public_id, loops)
        Rho::Host.resolve(public_id, rows: store.rows,
          fetch_loop: ->(id) { loops.agent_loop(id).fetch })
      end

      # Written on the workspace-adopted edge — boot;
      # a `rho env` repoint rebuilds the runner, re-announces, and runs the
      # edge again (`Context#repoint_tools`): the declaration reads the
      # registry, never the root, but the named definitions beside it are
      # the root's and the tuple makes an
      # unchanged set a no-op. The bytes are the UNION over this
      # machine's registry and every bound or selected runner's announced
      # list (`Bindings#declare`), written only when they move. A
      # running turn keeps its frozen bytes, and a refusal costs the
      # declaration, never the runner. Answers the outcome (`Bindings#declare`).
      def declare_configuration(credential) = declare(@wire.client(credential))

      # THE STOP EDGE: the session grants
      # re-declared away on the member plane before the daemon disappears;
      # the count, for the caller's log.
      def revoke_grants(credential) = revoke_grants_and_declare(@wire.client(credential))

      # THE SETTINGS' POLICY, unless this address cannot serve it: a
      # `delegate` declaration names `summarize_history`, and an operator's
      # `extensions` list may have dropped the extension that registers it
      # — a name nobody announced would fail every wall `tool_not_served`,
      # so the daemon declares the kernel instead and says so once.
      def compaction_policy
        policy = @config.compaction_policy
        return policy unless policy["mode"] == "delegate"
        return policy if @loaded.registry.names.include?(policy.fetch("tool_name"))

        @log.warn("compaction.delegate_unserved", tool: policy.fetch("tool_name"),
          detail: "the extension registering it is not loaded; declaring the kernel's summarizer")
        policy.except("tool_name").merge("mode" => "kernel")
      end

      # THE SUMMARIZER SLOT'S TEXT:
      # the slot row's `summarizer_prompt` — the pinned row, else the row of
      # `compaction.model || default_model` — when the declared policy is
      # the kernel's; nil (the slot is deleted) under `off`, a text-less
      # row, or a `delegate` policy that reads nothing from it.
      def summarizer_text(policy)
        return nil unless policy.fetch("mode") == "kernel"

        choice = @adaptations.summarizer
        choice.off? ? nil : choice.row.summarizer_prompt
      end

      # Fetched, never carried, and cached for the daemon's life (the catalog
      # is the kernel's constant). An unreachable catalog is a smaller run,
      # not a refused one: logged, and the next caller asks again. With no
      # client to ask — a hook shaping a turn — the answer is what the boot
      # declaration fetched. The catalog's plain set becomes the UNIVERSE
      # under the BOOT ROW of the SDK's adaptations pack (the row's preset aliases beside or in place of `task`/`ask`, each `recut` rendered against the template the kernel SERVED — a moved anchor is `AnchorMoved`, loud, never a silent plain text).
      # With a `model`, the set is the tier's for that model under the
      # settings alone (no flag): what a standalone loop seeds, from the
      # same resolver a conversation turn uses — the compose switch, its
      # rung the model's row.
      def kernel_tool_definitions(client = nil, model: nil)
        catalog = kernel_catalog(client)
        definitions = @adaptations.apply(catalog.definitions, templates: catalog.templates)
        return definitions if model.nil?

        decision = ComposeSwitch.resolve(flag: nil, config: @config, row: compose_row(model))
        ComposeSwitch.narrow(definitions, ComposeSwitch.tool_names(definitions, decision))
      end

      # The compose rung's subject: the model's row, none under `off`.
      def compose_row(model)
        choice = @adaptations.for(model)
        choice.off? ? nil : choice.row
      end

      private

        # ONE fetch (`client.tools.list`) answers both halves: the
        # definitions for the names the settings declare — a name the
        # kernel does not serve is an ERROR, never a silent omission, as
        # the SDK's `definitions_for` rules — and every served template.
        def kernel_catalog(client)
          names = @config.kernel_tools
          return Catalog.none if names.empty?
          return @kernel_catalog || Catalog.none if client.nil?

          @kernel_catalog ||= begin
            served = client.tools.list.to_h { |entry| [entry.canonical_name, entry] }
            definitions = names.map do |name|
              entry = served[name]
              raise CybrosAgent::Api::UnknownKernelTool, "the kernel serves no tool named #{name}" if entry.nil?

              entry.definition
            end
            Catalog.new(definitions: definitions, templates: served.transform_values(&:template).compact)
          end
        rescue StandardError => error
          @log.warn("kernel_tools_unavailable", names: names,
                    error_class: error.class.name)
          Catalog.none
        end

        # The followed run whose turns a loop id backed, current or earlier
        # — the run's own predicate, which the Ops listing reads by too.
        def backed_by(public_id) = @lineage.runs.find { |run| run.backs?(public_id) }

        # The member plane, then the host a followed id names (an id the
        # store does not know is refused — `rho attach` first), then that
        # host's own SDK context for the block to speak through, the
        # workspace, and the client itself (the catalog is read through it).
        def host_command(request, ctx)
          ctx.member_plane(request, body: true) do |client, workspace_public_id, _about, body|
            public_id = body["public_id"].to_s
            next Refusal.malformed("public_id is required") if public_id.empty?

            row = store.find(public_id)
            next Refusal.not_followed(public_id, lane: :host, hint: "attach it first") if row.nil?

            host = row.host
            workspace = client.workspace(row.workspace)
            row = hydrate_policy(row, host.context(workspace)) if host.outlives_turn?
            yield(host, host.context(workspace), row, body, workspace, client)
          end
        end

        # `:turn_author`, in registration order, fail-CLOSED: the open is
        # refused rather than authored without what an extension meant to
        # add. A hook answers the Draft the next one sees, or a Refusal.
        def author_hooks(draft, ctx)
          @loaded.daemon_hooks.select { |hook| hook.event == :turn_author }.reduce(draft) do |current, hook|
            answer = hook.handler.call(current, ctx)
            case answer
            in Refusal then return answer
            in Draft then answer
            end
          rescue StandardError => error
            @log.warn("turn_author_hook_failed", extension: hook.extension,
              error_class: error.class.name, error: CybrosAgent::Redaction.call(error.message))
            return Refusal.extension_failed(hook.extension, error)
          end
        end

        # `:turn_follow`, fired with the LOOP backing the turn, fail-OPEN: a
        # hook that raises costs that gate, never the follower. One gate per
        # loop; the first answered stands.
        def follow_gate(loop_public_id, notes, ctx)
          gates = @loaded.daemon_hooks.select { |hook| hook.event == :turn_follow }.filter_map do |hook|
            hook.handler.call(loop_public_id, notes, ctx)
          rescue StandardError => error
            @log.warn("turn_follow_hook_failed", extension: hook.extension, agent_loop: loop_public_id,
              error_class: error.class.name)
            nil
          end
          @log.warn("loop_gate_ambiguous", agent_loop: loop_public_id, gates: gates.length) if gates.length > 1
          gates.first
        end

        def store
          user = @context.own_user_public_id
          @stores ||= {}
          @stores[user] ||= Rho::HostStore.new(@home.host_cache_path(user || "unconnected"))
        end
    end
  end
end
