require "json"

module E2E
  # THE HARNESS EXECUTOR'S TOOLS: four read-only echo handlers and two SLOW ones — one per effect
  # profile — registered through the runner gem's own extension door so the load-time contract
  # (`Rho::Runner::Extensions::Tool`) checks them the way it checks anybody's. Each answers
  # `echo:<name>:<arguments as JSON>` — a result no other executor could have produced, which is how
  # a journey tells the process's answer from rho's.
  #
  # Loaded in TWO processes: the executor script serves them, and rho under
  # the empty-extensions prelude DECLARES them (a round admits only the
  # names its declaration carried), so nothing here depends on either host
  # beyond the runner gem's `Result`. Both render the announcement through
  # the registry's ONE renderer (`Registry#announcement`): no module here
  # renders an entry of its own.
  module EchoTools
    NAME = "e2e.echo".freeze

    # The kernel's closed vocabulary for a pure read; the five keys the
    # announcement door requires on every entry.
    READ_ONLY = {
      "kind" => "read_only", "destructive" => false, "world" => "closed",
      "idempotency" => "intrinsic", "reconciliation" => "none",
    }.freeze

    # An open-world write nothing reconciles: the profile the sweep reads as NOT replayable — a
    # claim on it that expires with no answer settles `uncertain`, never `timed_out`.
    WRITE = {
      "kind" => "write", "destructive" => true, "world" => "open",
      "idempotency" => "none", "reconciliation" => "none",
    }.freeze

    # SHORT, and announced: the park's deadline when a call authors none, ONE number every harness
    # tool class declares as its own `TIMEOUT_MS` — the runner gem's contract reads a class's OWN
    # constants (`Tool.timeout_ms`), so the announcement the registry renders and the park the
    # runner asks to extend are this constant read off the class, never a second copy. Thirty
    # seconds is enough for an echo, short enough that a journey's clock notices a row the process
    # never took, and — under the runner's quarter headroom — leaves a slow handler 22.5 s before
    # its own clamp would answer for it.
    TIMEOUT_MS = 30_000

    PATH_SCHEMA = {
      "type" => "object",
      "properties" => { "path" => { "type" => "string", "description" => "A path" } },
      "additionalProperties" => true,
    }.freeze

    SECONDS_SCHEMA = {
      "type" => "object",
      "properties" => { "seconds" => { "type" => "number", "description" => "How long to take" } },
      "additionalProperties" => true,
    }.freeze

    # The handler every echo tool shares: cancellation is honoured at the
    # one checkpoint it has, then the arguments come back as they arrived.
    class Echo
      def initialize(env:)
        @env = env
      end

      def call(args)
        Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
        Rho::Runner::Result.ok("echo:#{self.class::NAME}:#{JSON.generate(args)}")
      end
    end

    class Read < Echo
      NAME = "read".freeze
      DESCRIPTION = "Echoes a read request (E2E harness executor).".freeze
      SCHEMA = PATH_SCHEMA
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    class Grep < Echo
      NAME = "grep".freeze
      DESCRIPTION = "Echoes a grep request (E2E harness executor).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "pattern" => { "type" => "string", "description" => "A pattern" },
          "path" => { "type" => "string", "description" => "A path" },
        },
        "additionalProperties" => true,
      }.freeze
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    class Ls < Echo
      NAME = "ls".freeze
      DESCRIPTION = "Echoes an ls request (E2E harness executor).".freeze
      SCHEMA = PATH_SCHEMA
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    class Find < Echo
      NAME = "find".freeze
      DESCRIPTION = "Echoes a find request (E2E harness executor).".freeze
      SCHEMA = PATH_SCHEMA
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    # A HANDLER THAT TAKES ITS TIME: sleeps `seconds` in short slices, honouring cancellation at
    # every one — a cooperative tool the clamp can end inside its grace — then echoes. A journey
    # kills the process while one is mid-sleep, which leaves the claim answered by nobody: the one
    # shape that reaches the sweep's rule.
    class Slow < Echo
      SLICE_SECONDS = 0.05

      # `seconds` is wall time on the monotonic clock, not a count of
      # slices: each `sleep` overshoots by a few milliseconds, and four
      # hundred of them ran a 20-second call to 23 seconds — past the
      # clamp's 22.5 s of a 30-second park — on a loaded machine.
      def call(args)
        deadline = now + Float(args["seconds"] || 0)
        while (remaining = deadline - now).positive?
          Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
          sleep([SLICE_SECONDS, remaining].min)
        end
        super
      end

      private

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    class SlowRead < Slow
      NAME = "slow_read".freeze
      DESCRIPTION = "Takes `seconds`, then echoes (E2E harness executor; replayable).".freeze
      SCHEMA = SECONDS_SCHEMA
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    class SlowWrite < Slow
      NAME = "slow_write".freeze
      DESCRIPTION = "Takes `seconds`, then echoes (E2E harness executor; an open-world write).".freeze
      SCHEMA = SECONDS_SCHEMA
      EFFECT_PROFILE = WRITE
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    # A CAPTURE (the `capture_upload` journey): the handler is the plain echo; the harness
    # executor's COMMIT DOOR (`ExecutorMain:: CaptureDoor`) stages the red-square PNG on the
    # executor plane and names it with a `resource_link` beside this text, `title` and `metadata` —
    # the script builds its own block, the runner gem owns its separate upload site. `link_to` names
    # an upload id to link INSTEAD of the staged one (a foreign id: the kernel's
    # `unknown_result_upload`); `orphan` stages the PNG and links nothing (a capture nobody names).
    class Capture < Echo
      NAME = "capture".freeze
      DESCRIPTION = "Takes a screenshot (E2E harness executor: stages a PNG and links it).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => {
          "link_to" => { "type" => "string", "description" => "An upload id to link instead of the capture" },
          "orphan" => { "type" => "boolean", "description" => "Stage the capture and link nothing" },
          "filename" => { "type" => "string", "description" => "Stage text under this name instead of the PNG" },
        },
        "additionalProperties" => true,
      }.freeze
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    # STRUCTURE ALONE: a result with `structured_content` and NO text — the model reads `""`, the
    # task read serves the structure whole. The runner gem sends exactly that.
    class Structure < Echo
      NAME = "structure".freeze
      DESCRIPTION = "Answers structure with no words (E2E harness executor).".freeze
      SCHEMA = PATH_SCHEMA
      EFFECT_PROFILE = READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS

      def call(args)
        Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
        Rho::Runner::Result.ok("", { "echo" => NAME, "arguments" => args })
      end
    end

    TOOLS = [Read, Grep, Ls, Find, SlowRead, SlowWrite, Capture, Structure].freeze


    class << self
      def names = TOOLS.map { |klass| klass::NAME }

      # The extension contract: what the loader calls. Runner tools, said
      # so (r-modes): a harness executor serves a machine address, and the
      # base handle admits nothing else.
      def register(api)
        TOOLS.each { |klass| api.register_tool(klass, serves: :runner) }
      end

      # The MCP `Tool` shape — the input to the SDK's lowering, for the
      # prelude that declares these on rho's profile.
      def declarations(selected = names)
        TOOLS.select { |klass| selected.include?(klass::NAME) }.map do |klass|
          { "name" => klass::NAME, "description" => klass::DESCRIPTION, "inputSchema" => klass::SCHEMA }
        end
      end

      # THE ANNOUNCED ENVIRONMENT: where this runner's relative paths resolve, as ONE fragment in
      # the sentence shape rho's own runner announces (`Coding::Report`) — so a lead rendered from
      # the snapshot by a rho elsewhere names the root and nothing else. A harness process given no
      # root announces none (the kernel stores `{}`): the provider journeys' leads name no root.
      def environment(root)
        {
          "root" => root,
          "fragments" => [{ "extension" => NAME, "text" => "Relative paths resolve against #{root}." }],
        }
      end
    end
  end

  # THE ANNOUNCED DOCUMENT AND THE `skill` THAT SERVES IT (the `skills` journey): a harness runner
  # announcing ONE document under `documents` and serving the kernel name `skill` is the routing pin
  # through a NON-rho announcer — a load of `echo-notes` reaches this process's inbox as the same
  # `skill` row and the echo is its result. Kept OUT of `EchoTools::TOOLS` like the guarded `bash`:
  # that list is the default a process announces AND what the empty-extensions prelude declares as
  # rho's own, and a `skill` in either would collide with the kernel's `skill` at compile
  # (`duplicate_tool_name`). A process names it with `--tools`; the documents ride the announcement
  # only when it does.
  module SkillTools
    DOCUMENTS = [
      { "name" => "echo-notes", "description" => "Echoes a skill load (E2E harness executor)." },
    ].freeze

    class Skill < EchoTools::Echo
      NAME = "skill".freeze
      DESCRIPTION = "Echoes a skill load (E2E harness executor).".freeze
      SCHEMA = {
        "type" => "object",
        "properties" => { "name" => { "type" => "string", "description" => "A skill name" } },
        "additionalProperties" => true,
      }.freeze
      EFFECT_PROFILE = EchoTools::READ_ONLY
      TIMEOUT_MS = EchoTools::TIMEOUT_MS
    end

    TOOLS = [Skill].freeze

    class << self
      def names = TOOLS.map { |klass| klass::NAME }

      def register(api)
        TOOLS.each { |klass| api.register_tool(klass, serves: :runner) }
      end

      # The documents a process announces beside its tools: the one
      # document when `skill` is among the announced names, else nil —
      # every other journey's process announces none.
      def documents(selected)
        DOCUMENTS if selected.include?(Skill::NAME)
      end
    end
  end
end
