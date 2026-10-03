require "json"

module Rho
  # THE SETTINGS FILE, which this daemon did not have. Every knob it needs
  # was a hard-coded default or a per-launch flag, which is workable while
  # rho runs on the laptop in front of you and is not once it runs on a
  # server you reach from elsewhere: a flag is not a deployment, and a
  # passphrase on a command line is in the shell history and in `ps`.
  #
  # ONLY KEYS WITH A CONSUMER. The predecessor's config carried twenty-five,
  # most of them for a loop that now lives in the kernel; carrying them here
  # would be settings nothing reads. Each key below names the code that
  # reads it.
  #
  # PRECEDENCE, lowest to highest: defaults, the settings file, the
  # environment, then an explicit CLI flag. The environment beats the file
  # because that is how a container or a systemd unit supplies a secret; the
  # flag beats everything because it is the most local statement of intent.
  class Config
    # `access_passphrase` — Rho::AccessLock. The one key with NO CLI flag,
    # deliberately: a passphrase passed as an argument is in the shell
    # history and readable in `ps` by every user on the host.
    #
    # `bind` — Daemon.verify_bind / ControlServer. A home-server deployment
    # states this once rather than on every launch.
    #
    # `api_only` — the webui mount. Headless deployments serve the control
    # routes and the unlock exchange and no page at all.
    #
    # `webui_root` — an explicit static build, overriding the directory
    # registered by rho-webui. A deployment may serve its own build without
    # changing the daemon or the plugin. `api_only` still disables the page.
    #
    # `bash_timeout_seconds` — Runner::ToolEnv, which has taken its own
    # default since it was written because nothing could tell it otherwise.
    # `extensions` / `extension_paths` — Rho::Extensions.load. "rho默认
    # 集成" is the default list in code; these ADD to it. Nothing is
    # discovered and auto-loaded: these tools run shell commands on the
    # operator's machine on behalf of a remote model, so a gem arriving as
    # somebody's transitive dependency must never become a tool.
    # `default_model` — Daemon::Loops#open and #say, Loops::Bindings#declare.
    # Rho's OWN model, as provider/reference: what
    # `rho do` opens a conversation on when `--model` names none (`open`
    # refuses `model is required` when neither states one — a new
    # conversation has no wire to read); what a `say` on a row this daemon
    # only attached rides before the addressed turn's own model (the loop
    # projection's `turn.model`; a refusal only when the wire carries none
    # either); and the profile fact `default_model` the daemon declares, so
    # the kernel answers every turn addressed to rho on it before the
    # initiator's. Unset, the initiator's model governs those turns.
    # `fallback_model` — Loops::Bindings#declare. THE FALLBACK ON REFUSAL OR
    # OVERLOAD, as provider/reference: the profile fact `fallback_model` the
    # daemon declares beside `default_model`, so the kernel re-runs a step
    # rho answers — or a one-shot rho creates, the delegate summarizer's —
    # ONCE on it when a provider's classifier declined the step
    # (`finish_quality: refused`) or the provider was overloaded on every
    # attempt of its budget (`provider_overloaded`) — never for an
    # unavailable model, a rate limit or an error, and never for a content
    # block (`blocked`), which is re-sent to nobody. Unset, a declined step
    # fails `model_refused` (an overloaded one `provider_overloaded`) and the
    # model reading it is told nothing re-ran it.
    # It may equal `default_model`: a turn on `rho do --model X` then falls
    # back home. Another Claude model is the vendor's own recommendation
    # for a Claude refusal (its classifiers are calibrated per model); a
    # model of another vendor is this setting's choice, and it carries the
    # refused step's WHOLE context — tool results included — to that
    # vendor under its enforcement and retention. A named definition that
    # names no `model:` inherits it (`LoopRequest.derived_declaration`).
    # Refused under mode runner, which declares no profile (the
    # `image_model` precedent). `RHO_FALLBACK_MODEL` spells it; `rho
    # status` prints what the kernel holds.
    # `compose` — Rho::ComposeSwitch.resolve, the one resolver of a turn's
    # compose tier: `on`, `off`, or
    # `auto` — the default — where `auto` reads the model's adaptation
    # row's `compose` word and takes a row saying
    # nothing as on. The `rho do` flag beats both.
    # `adaptations` / `adaptations_dir` — Rho::Adaptations, rho's ONE knob
    # over the SDK's model-adaptations pack: `auto` — the default — applies the pack's row for a
    # model (the gem's rows matched by model pattern, the claude/codex
    # preset rows for the models they cover included); `off` declares the
    # kernel's plain set; a row id pins that row for every model.
    # `RHO_ADAPTATIONS` spells it. `adaptations_dir` (default
    # `<home>/adaptations`, no environment spelling) holds LOCAL rows —
    # whole rows the operator writes for a model no gem row covers or to
    # replace the gem's row; a local row that replaces none answers before
    # every gem row, every text field the operator's. A local row IS the
    # per-model override: universe, compose, texts — the three per-model
    # tables this replaced are gone. The BOOT
    # row (the pinned row, else the row of `default_model`, else
    # `default`) is the universe the profile declares; a row change is a
    # boot, as a `kernel_tools` change is: the declaration is the front of
    # the cached prefix.
    # `tools_root` — Runner::ToolEnv#root. WHERE A BARE RELATIVE PATH
    # LANDS, and the one environment fact this daemon holds. It took its
    # own default because nothing could state it — the same shape
    # `bash_timeout_seconds` was in — which meant every relative path a
    # model wrote resolved under a scratch directory rather than under
    # the operator's code. An operator who works in one place says so
    # once; anything outside it is reached by absolute path, which every
    # tool here already accepts.
    # `executor_socket` — Daemon#place_runner. Whether the runner's second
    # cable — the executor inbox channel, on the transport credential — is
    # opened beside the sweep. On by default. Off is the
    # sweep-only mode: the cable is latency only and the inbox is the
    # truth, so the product WORKS without it, and the e2e cable-killed
    # journey (E4) proves exactly that — `nudged: 0` beside a rising
    # `claimed`. A test-only knob in the sense that no operator wants it.
    # `compaction` — LoopRequest.declaration through `compaction_policy`,
    # and the `summarize_history` tool through `compaction_model`. An object `{mode, model}`: `mode` is `kernel` — the
    # default, the kernel's own summarizer —
    # or `delegate`, under which the profile declares rho's own
    # `summarize_history` and the kernel addresses each compaction to this
    # address as an inbox row; `model` is the provider/reference the
    # summary OneShot runs on, falling to `default_model`, and one of the
    # two is REQUIRED under `delegate` because the row names none. Under
    # `kernel`, an explicit `model` overrides the current turn's model
    # for summaries. It also picks the SLOT ROW of the SDK's adaptations
    # pack (`Rho::Adaptations#summarizer`), falling to the boot default's
    # row for the profile's `summarizer` text when unset.
    # `RHO_COMPACTION` spells the mode only.
    # `mode` — WHAT THIS RHO IS: `full` serves tools AND drives
    # conversations on two addresses; `agent` drives conversations and
    # names a runner; `runner` serves tools alone and holds no member
    # credential. A boot fact like `bind`: settings, `RHO_MODE`, `--mode`
    # on `rho server`; the daemon never writes it, and a home paired in
    # another mode is refused at boot with the switch sentence.
    # `runner` — the runner new hosts start on when `rho do --runner` names
    # none: a runner-kind executor's public id, written by `rho runners
    # use` FROM THE CLI PROCESS (correction (f)); nil = rho's
    # own runner row when it registered one, else none. No environment
    # spelling. READ BY NOTHING AT RUN TIME: `Daemon::Context#runner_selection`
    # reads the key FRESH off the settings file (`Home#settings_runner`)
    # on every `rho do` and standalone author, because the daemon writes
    # settings never and a boot-time copy would miss the person's next
    # `rho runners use`; the value here is the boot's, for this class's
    # own validation alone.
    # `workspace` — the default for NEW conversations. The settings value
    # is read fresh, as runner selection is; `RHO_WORKSPACE` and an explicit
    # `rho server --workspace` remain boot overrides. Nil adopts this agent's
    # oldest dedicated workspace, creating one if needed. Existing hosts
    # keep their own workspace. Runner mode holds no member plane.
    # `mcp_servers` — `rho/mcp` (an extension gem; rho keeps the table as an object of objects and reads NOTHING inside it: which servers, their transports, their tools and their `${NAME}` secrets are the extension's to judge at load, per server). A
    # table is not an environment variable, so it has no spelling there.
    # `checkpoints` — the runner's shadow store: whether the
    # daemon opens one for its runner root, how long a loop's record is
    # kept, the per-file cap an UNTRACKED file is excluded over, the tree
    # cap a capture is skipped over, and the wall clock every capture runs
    # under. Five knobs, one object; a table is not an environment
    # variable, so it has no spelling there.
    # `image_model` — `Rho::Extensions::Images`: the provider/reference the agent's own
    # `image_generate` tool places its `image_generation` OneShot on. A
    # SETTING, never a hardcoded id (codex names `gpt-image-2` at
    # `tool.rs:59`): unset, the extension registers nothing and no model
    # is offered the tool; set, the tool is offered and the kernel's
    # selection judges the row at every call (an unavailable model or a
    # text row is the kernel's own refusal, relayed as text). Refused
    # under mode runner, which opens no member plane (the `workspace`
    # precedent). `RHO_IMAGE_MODEL` spells it.
    # `web` — `rho/web-tools` (an extension gem; rho keeps the table as an object and reads NOTHING inside it: the private-network allowance is the extension's to judge at load). A
    # table is not an environment variable, so it has no spelling there.
    # `acp_agents` — `rho/acp-client` (an extension gem): the ACP agents this rho may delegate to, one row per agent
    # under the person's short word — `{command, args, env, description,
    # permissions allow|reject, timeout_ms, auth_method, model, enabled}`,
    # `${NAME}` in `env` expanded from the daemon's environment. Kept as
    # `mcp_servers` is: an object of objects rho reads NOTHING inside,
    # because a row is judged PER ROW at the extension's load — a bad row
    # is that row's fault, listed `down: config:` and contributing no
    # tool, never this boot's refusal — and only the table's own shape is
    # refused here by name. A table is not an environment variable, so it
    # has no spelling there.
    KEYS = %w[
      access_passphrase bind api_only bash_timeout_seconds tools_root webui_root
      extensions extension_paths kernel_tools default_model compose adaptations adaptations_dir
      executor_socket compaction lifecycle_hooks mode runner workspace mcp_servers checkpoints web image_model acp_agents telegram
      fallback_model
    ].freeze

    ENV_KEYS = {
      "access_passphrase" => "RHO_ACCESS_PASSPHRASE",
      "bind" => "RHO_BIND",
      "api_only" => "RHO_API_ONLY",
      "bash_timeout_seconds" => "RHO_BASH_TIMEOUT_SECONDS",
      "tools_root" => "RHO_TOOLS_ROOT",
      "webui_root" => "RHO_WEBUI_ROOT",
      "default_model" => "RHO_DEFAULT_MODEL",
      "compose" => "RHO_COMPOSE",
      "adaptations" => "RHO_ADAPTATIONS",
      "executor_socket" => "RHO_EXECUTOR_SOCKET",
      "compaction" => "RHO_COMPACTION",
      "mode" => "RHO_MODE",
      "workspace" => "RHO_WORKSPACE",
      "image_model" => "RHO_IMAGE_MODEL",
      "fallback_model" => "RHO_FALLBACK_MODEL",
    }.freeze

    DEFAULTS = {
      "access_passphrase" => nil,
      "bind" => nil,
      "api_only" => false,
      # Runner::ToolEnv's own default, restated here so the two cannot
      # disagree silently; the runner keeps its default for the standalone
      # case where no daemon composes it.
      "bash_timeout_seconds" => 120,
      # nil means the daemon's own identity work root — a value only the
      # daemon can compute, so the default cannot live here.
      "tools_root" => nil,
      "webui_root" => nil,
      "extensions" => [],
      "extension_paths" => [],
      # WHAT THE KERNEL DOES FOR A MODEL, beside what this machine does.
      # `compose` authors a round as a graph — work combined by a step the
      # model keeps out of its own context, `g.ask` in the middle of it;
      # `task` and `ask` are the flat verbs beside it, so a model without compose can still start a branch
      # and still put a question to the person running it; the six memory
      # verbs are how a turn writes a note the next turn reads back; the four conversation verbs
      # open a conversation with another agent — a subagent or a peer —
      # and keep talking to it.
      #
      # A LIST AN OPERATOR CAN EMPTY, and emptying it is a real choice
      # rather than a saving: the declaration is the front of the cached
      # prefix, so turning a kernel tool on or off between loops is free
      # and turning it on MID-loop is not. THE UNIVERSE, not the tier: the
      # compose switch below withholds `compose` from one conversation and
      # never adds it, so removing it here switches it off for good.
      # `nexus.skill.load` is rho's "whether to declare skills at all":
      # the profile declares it like any kernel
      # tool; the kernel omits it from the wire while the loop's merged
      # catalog is empty, so declaring it costs nothing on a checkout
      # without skills.
      "kernel_tools" => %w[
        nexus.graph.compose nexus.graph.task nexus.human.ask
        nexus.memory.read nexus.memory.write nexus.memory.edit
        nexus.memory.ls nexus.memory.grep nexus.memory.delete
        nexus.conversation.spawn nexus.conversation.send
        nexus.conversation.status nexus.conversation.cancel
        nexus.conversation.search nexus.conversation.read
        nexus.skill.load
      ],
      "default_model" => nil,
      "compose" => "auto",
      # THE PACK'S ROW PER MODEL (Rho::Adaptations): a text a measurement
      # earns lands in the SDK's row; nil `adaptations_dir` is `<home>/adaptations`.
      "adaptations" => "auto",
      "adaptations_dir" => nil,
      "executor_socket" => true,
      "compaction" => { "mode" => "kernel" }.freeze,
      "lifecycle_hooks" => {},
      "mode" => "full",
      "runner" => nil,
      "workspace" => nil,
      "mcp_servers" => {},
      "checkpoints" => {
        "enabled" => true, "retention_days" => 7, "max_file_bytes" => 2_097_152,
        "max_tree_bytes" => 268_435_456, "capture_timeout_seconds" => 30,
      }.freeze,
      "web" => {},
      "telegram" => {},
      "image_model" => nil,
      "acp_agents" => {},
      "fallback_model" => nil,
    }.freeze

    CHECKPOINT_KEYS = %w[enabled retention_days max_file_bytes max_tree_bytes capture_timeout_seconds].freeze
    # The store's own defaults, restated: the two cannot disagree silently.
    CHECKPOINT_DEFAULTS = DEFAULTS.fetch("checkpoints")

    COMPACTION_MODES = %w[kernel delegate].freeze
    COMPACTION_KEYS = %w[mode model].freeze
    MODES = %w[full agent runner].freeze

    # A bash timeout past the kernel's own task deadline would be a promise
    # the park cannot keep; the runner's Bash tool carries the same ceiling.
    MAX_BASH_TIMEOUT_SECONDS = 540

    # The keys an environment variable spells as a switch (`1`, `true`,
    # `yes`, `on`) rather than as a value.
    SWITCHES = %w[api_only executor_socket].freeze

    class << self
      # `flags` are the CLI's own words for a key (`rho server --mode`), the
      # most local statement of intent; a nil flag states nothing.
      def load(path, env: ENV, flags: {})
        environment = from_env(env)
        explicit = flags.transform_keys(&:to_s).compact
        build(deep_merge(read(path), environment).merge(explicit),
          workspace_override: environment.key?("workspace") || explicit.key?("workspace"))
      end

      def from_hash(hash)
        build(hash, workspace_override: true)
      end

      def build(hash, workspace_override:)
        merged = DEFAULTS.merge(hash.transform_keys(&:to_s).slice(*KEYS))
        new(**merged.transform_keys(&:to_sym), workspace_override: workspace_override)
      end
      private :build

      # The operator's file as an object — absent is empty, anything but
      # an object is refused by name. Public because the one key the daemon
      # reads fresh (`Home#settings_runner`) and the one the CLI writes
      # (`Home#write_setting`) go through the same reader.
      def read(path)
        return {} unless path && File.file?(path)

        parsed = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        unless parsed.is_a?(Hash)
          raise ConfigurationError, "#{path} must contain a JSON object"
        end

        parsed
      rescue JSON::ParserError => error
        raise ConfigurationError, "#{path} is not valid JSON: #{error.message}"
      end

      private

        # An empty variable is UNSET, not an empty value: `RHO_BIND=` in a
        # unit file is how an operator disables an override, and reading it
        # as "" would bind nowhere.
        def from_env(env)
          ENV_KEYS.each_with_object({}) do |(key, name), hash|
            value = env[name]
            next if value.nil? || value.empty?

            hash[key] =
              if SWITCHES.include?(key) then truthy(value)
              elsif key == "compaction" then { "mode" => value }
              else value
              end
          end
        end

        def truthy(value) = %w[1 true yes on].include?(value.to_s.downcase)

        # One level: the environment spells the compaction MODE over the
        # file's object and keeps the file's model.
        def deep_merge(base, overlay)
          base.merge(overlay) do |_key, old, new|
            old.is_a?(Hash) && new.is_a?(Hash) ? old.merge(new) : new
          end
        end
    end

    attr_reader :access_passphrase, :bind, :api_only, :bash_timeout_seconds,
      :tools_root, :webui_root, :extensions, :extension_paths, :kernel_tools, :default_model,
      :compose, :adaptations, :adaptations_dir, :executor_socket, :compaction,
      :mode, :runner, :workspace, :mcp_servers, :checkpoints, :web, :image_model, :acp_agents, :lifecycle_hooks,
      :fallback_model, :telegram, :workspace_override

    def workspace_selection(home) = workspace_override ? workspace : home.settings_workspace

    def initialize(access_passphrase:, bind:, api_only:, bash_timeout_seconds:,
                   tools_root:, webui_root:, extensions:, extension_paths:, kernel_tools:,
                   default_model:, compose:, adaptations:, adaptations_dir:,
                   executor_socket:, compaction:, mode:, runner:, workspace:, mcp_servers:, checkpoints:, web:,
                   image_model:, acp_agents:, lifecycle_hooks:, fallback_model:, telegram: {}, workspace_override: true)
      @mode = one_of(mode, "mode", MODES)
      @runner = presence(runner)
      @workspace = room(workspace, @mode)
      @workspace_override = workspace_override && !@workspace.nil?
      @image_model = agent_model(image_model, "image_model", @mode)
      @fallback_model = agent_model(fallback_model, "fallback_model", @mode)
      @access_passphrase = AccessLock.validate!(presence(access_passphrase))
      @bind = presence(bind)
      @api_only = api_only == true || truthy?(api_only)
      @bash_timeout_seconds = bounded_timeout(bash_timeout_seconds)
      @tools_root = expanded(tools_root)
      @webui_root = expanded(webui_root)
      @extensions = string_list(extensions, "extensions")
      @extension_paths = string_list(extension_paths, "extension_paths")
      @kernel_tools = string_list(kernel_tools, "kernel_tools")
      @default_model = presence(default_model)
      @compose = one_of(compose, "compose", ComposeSwitch::MODES)
      @adaptations = Adaptations.knob(adaptations)
      @adaptations_dir = expanded(adaptations_dir)
      @executor_socket = executor_socket == true || truthy?(executor_socket)
      @compaction = compaction_object(compaction, @default_model, @mode)
      @mcp_servers = object_table(mcp_servers, "mcp_servers")
      @acp_agents = object_table(acp_agents, "acp_agents")
      @checkpoints = checkpoints_object(checkpoints)
      @web = opaque_object(web, "web")
      @telegram = opaque_object(telegram, "telegram")
      @lifecycle_hooks = opaque_object(lifecycle_hooks, "lifecycle_hooks")
      freeze
    end

    # THE PROFILE'S POLICY, as the declaration sends it: the kernel's by
    # default, with the explicitly configured summary model when given;
    # under `delegate`, rho's own summarizer by NAME — the arm
    # addresses the delegate row to whichever address announced that name.
    def compaction_policy
      return { "mode" => "kernel", "model" => compaction_model }.compact unless @compaction.fetch("mode") == "delegate"

      { "mode" => "delegate", "tool_name" => Extensions::Compaction::TOOL_NAME }
    end

    # The explicit summary model. The delegated tool falls to default_model;
    # a kernel summary with none inherits the current turn's model.
    def compaction_model = @compaction["model"]

    private

      def presence(value)
        text = value.to_s
        text.empty? ? nil : text
      end

      # A runner constructs no member plane and adopts nothing: a room
      # named there would be a promise the boot cannot keep.
      def room(value, rho_mode)
        address = presence(value)
        raise ConfigurationError, "workspace needs mode full or agent" if address && rho_mode == "runner"

        address
      end

      # A model only the agent's plane reads — the one its own tool places
      # a OneShot on, the fallback its profile declares: a runner holds no
      # member plane, so a value there would be a setting that lies.
      def agent_model(value, name, rho_mode)
        model = presence(value)
        raise ConfigurationError, "#{name} needs mode full or agent" if model && rho_mode == "runner"

        model
      end

      def truthy?(value) = %w[1 true yes on].include?(value.to_s.downcase)

      # `~` is what an operator writes in a settings file, and a tool
      # resolving paths against a literal "~/src" would create a
      # directory called "~".
      def expanded(value)
        path = presence(value)
        path && File.expand_path(path)
      end

      def string_list(value, name)
        list = Array.try_convert(value)
        raise ConfigurationError, "#{name} must be an array of strings" if list.nil?

        list.map { |entry| entry.to_s }.reject(&:empty?).freeze
      end

      def one_of(value, name, words)
        word = value.to_s.strip.downcase
        unless words.include?(word)
          raise ConfigurationError, "#{name} must be one of #{words.join(", ")}, got #{value.inspect}"
        end

        word
      end

      # An object whose keys are strings and whose values are objects, and
      # nothing more: what is inside each row is its consumer's to judge.
      def object_table(value, name)
        table = Hash.try_convert(value)
        raise ConfigurationError, "#{name} must be an object of objects" if table.nil?

        table.each do |key, row|
          raise ConfigurationError, "#{name}[#{key}] must be an object" if Hash.try_convert(row).nil?
        end
        table.to_h { |key, row| [key.to_s, row.to_h.freeze] }.freeze
      end

      # An object, and nothing more: what is inside is its consumer's to
      # judge (`object_table` would refuse a table whose values are not
      # objects — `{"allow_private_network": false}` — at boot).
      def opaque_object(value, name)
        table = Hash.try_convert(value)
        raise ConfigurationError, "#{name} must be an object" if table.nil?

        table.to_h { |key, entry| [key.to_s, entry] }.freeze
      end

      # A runner declares no profile, so a delegate it would never announce
      # to the kernel is a setting that lies; refused where it is read.
      def compaction_object(value, default_model, rho_mode)
        table = Hash.try_convert(value)
        if table.nil?
          raise ConfigurationError, "compaction must be an object {#{COMPACTION_KEYS.join(", ")}}, got #{value.inspect}"
        end

        unknown = table.keys.map(&:to_s) - COMPACTION_KEYS
        raise ConfigurationError, "compaction names #{unknown.first}, not one of #{COMPACTION_KEYS.join(", ")}" unless unknown.empty?

        mode = one_of(table.fetch("mode", "kernel"), "compaction.mode", COMPACTION_MODES)
        model = presence(table["model"])
        if mode == "delegate" && rho_mode == "runner"
          raise ConfigurationError, "compaction.mode delegate needs mode full or agent — a runner declares no profile"
        end
        if mode == "delegate" && model.nil? && default_model.nil?
          raise ConfigurationError, "compaction: delegate needs compaction.model or default_model"
        end

        { "mode" => mode, "model" => model }.compact.freeze
      end

      # The five knobs over the defaults, each an integer where the store
      # takes one and a switch where it takes a switch; a key outside the
      # five is refused by name (a misspelled cap would silently keep the
      # default), as `compaction` refuses its shape.
      def checkpoints_object(value)
        table = Hash.try_convert(value)
        if table.nil?
          raise ConfigurationError, "checkpoints must be an object {#{CHECKPOINT_KEYS.join(", ")}}, got #{value.inspect}"
        end

        unknown = table.keys.map(&:to_s) - CHECKPOINT_KEYS
        raise ConfigurationError, "checkpoints names #{unknown.first}, not one of #{CHECKPOINT_KEYS.join(", ")}" unless unknown.empty?

        merged = CHECKPOINT_DEFAULTS.merge(table.transform_keys(&:to_s))
        enabled = merged.fetch("enabled")
        merged.each_key do |key|
          next if key == "enabled"

          number = Integer(merged.fetch(key), exception: false)
          unless number&.positive?
            raise ConfigurationError, "checkpoints.#{key} must be a positive integer, got #{merged.fetch(key).inspect}"
          end

          merged = merged.merge(key => number)
        end
        merged.merge("enabled" => enabled == true || truthy?(enabled)).freeze
      end

      def bounded_timeout(value)
        seconds = Integer(value, exception: false)
        unless seconds && seconds.positive? && seconds <= MAX_BASH_TIMEOUT_SECONDS
          raise ConfigurationError,
            "bash_timeout_seconds must be an integer between 1 and " \
            "#{MAX_BASH_TIMEOUT_SECONDS}, got #{value.inspect}"
        end

        seconds
      end
  end
end
