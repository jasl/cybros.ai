require "digest"
require "json"
require_relative "execution_policy"
require_relative "memory_policy"

module Rho
  # What rho sends when it starts a loop, and what it declares to its own
  # profile. The profile owns the model-visible tool list; executor
  # announcements separately own live routing. Rho builds its declaration
  # from announced tools, using this machine's registry in process and
  # discovery for a runner elsewhere. Each turn freezes that declaration
  # so later routing changes cannot rewrite its cached prompt prefix.
  module LoopRequest
    # The kernel refuses `tools: []` as a typo'd intent — authoring an
    # empty list reads like disabling something that was never on — so a
    # machine serving nothing authors no tools key at all.

    # The profile's standing declaration: `bypass` is rho's approval mode by product policy
    # — the kernel's stage runs on every tool row and grants by mode. `APPROVAL_RULES` is
    # the Guard's list in the kernel's grammar — deny rules that bind under EVERY mode, so
    # the calls no snapshot can undo are refused at the stage and never dispatched (the
    # runner-side Guard stays as the floor for a foreign agent's turn) — plus the
    # two allow rules, for the runner's read-only tools and for the kernel tools, inert
    # under `bypass` and the whole point of `rho do --approval ask|rules`: under `ask` a
    # command parks for a person while the reads and the kernel tools run; under `rules`
    # every command is refused as data and only the reads and the kernel tools run. The
    # kernel's own assembly; the compaction policy is the settings'
    # (`Rho::Config#compaction_policy`). The tool set is the runner's, then the kernel's.
    APPROVAL_MODE = "bypass".freeze
    PROMPT_MECHANISM = "assembly".freeze
    # Keep the default block order and append the current execution's fact
    # beside its input. In a leading slot it would rewrite a side's prefix.
    PROMPT_TEMPLATE = { "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "slot", "slot" => "character" },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" }, { "type" => "skills" }, { "type" => "history" },
      { "type" => "lead" }, { "type" => "tail" },
      ExecutionPolicy.context_block, { "type" => "input" },
    ] }.freeze

    # The two tools that run a command, in the rule grammar's `|` spelling
    # (`Extensions::Guard::GUARDED_TOOLS` is the runner's array of the same
    # fact; the test cross-pins them).
    GUARDED_TOOLS = "bash|start_process".freeze

    # THE RUNNER'S READS: read-only by construction —
    # each declares `kind: read_only, destructive: false, world: closed`
    # (`rho-runner/lib/rho/runner/tools/{read,grep,ls,find}.rb`,
    # `extensions/processes/tools.rb` READ_PROFILE) — so `ask` means "ask
    # before an EFFECT", as every reference does (claude-code
    # `FileReadTool.isReadOnly`, codex's auto-approved read-only commands,
    # opencode `read: allow`). `bash` stays a command (a `cat` is not a
    # read tool); the memory reads are the kernel's, inside `memory_*`.
    # Inert under `bypass`; a deny still wins wherever it sits. The test
    # cross-pins the list against the registry's effect profiles.
    #
    # THE MEMBERSHIP RULE: a `read_only` tool on
    # the CLOSED world — a read of this machine — is named here; a
    # `read_only` tool on the OPEN world (`web_fetch`, the II-7 search
    # after it) is NEVER named here — it runs under `bypass`, parks under
    # `ask` and is refused under `rules` until a rule allows it; and it
    # gets NO ask row of its own, because the evaluator collects every
    # matching rule with `ask` beating `allow`, so an ask row on the tool
    # would defeat every per-host allow — the operator's and the grant
    # verb's — and park it forever.
    READ_ONLY_TOOLS = "read|grep|ls|find|file_import|file_publish|read_process|list_processes|read_scheduled_jobs".freeze

    # One Guard regex becomes several globs: the grammar has no escape and
    # no character class (only `*` and `?` are special, anchored both ends,
    # `*` crossing a newline), so each is precise where a glob allows and
    # START-anchored where a substring glob would deny ordinary coding
    # commands (`grep -rn shutdown lib` is not "powering the machine off").
    # The reason is the Guard's own sentence, verbatim — it is what the
    # model reads, and model-facing names are load-bearing.
    def self.deny_rules(reason, *globs)
      globs.map do |glob|
        { "tool" => GUARDED_TOOLS, "path" => "command", "match" => glob,
          "verdict" => "deny", "reason" => reason }.freeze
      end
    end
    private_class_method :deny_rules

    APPROVAL_RULES = [
      *deny_rules("recursive delete of a root directory",
        "*rm -?? /", "*rm -?? / *", "*rm -?? /?", "*rm -?? /? *",
        "*rm -?? ~", "*rm -?? ~ *", "*rm -?? $HOME", "*rm -?? $HOME *"),
      *deny_rules("force push rewrites history others may hold; a person can run it",
        "*git push*--force*", "*git push* -f", "*git push* -f *"),
      *deny_rules("piping a download into a shell runs code nobody has read",
        "*curl*|*sh", "*curl*|*sh *", "*wget*|*sh", "*wget*|*sh *"),
      *deny_rules("elevation is not available to an unattended loop",
        "sudo", "sudo *", "*; sudo *", "*&& sudo *", "*| sudo *"),
      *deny_rules("formatting a filesystem", "*mkfs*"),
      *deny_rules("writing raw bytes to a device", "*dd *of=/dev/*"),
      *deny_rules("powering the machine off", "shutdown*", "reboot*", "halt*", "poweroff*"),
      *deny_rules("a fork bomb", "*:(){ :|:& };:*"),
      *deny_rules("opening the root filesystem to everyone", "*chmod *777 /", "*chmod *777 / *"),
      { "tool" => READ_ONLY_TOOLS, "verdict" => "allow" }.freeze,
      # The kernel's verbs and the `skill` load: a
      # read is never parked. A checkout's `SKILL.md` is a
      # prompt-injection door the kernel cannot judge, and the gate for it
      # IS this rules grammar: a stricter posture writes
      # `{tool: "skill", verdict: "ask"}` in its own rules. `todo_write`
      # is a memory write under rho's own name; a
      # bookkeeping write never parks.
      { "tool" => "memory_*|ask|task|compose|skill|todo_write|session_search|session_read", "verdict" => "allow" }.freeze,
    ].freeze

    # THE SELF-MODIFICATION DENIES: a running agent never edits its own checkout or its home
    # — it incubates a successor as a separate install, proves it, then upgrades. Enforced
    # by rho's OWN rules through the kernel's rule mechanism (no kernel ban), per install,
    # so a method beside the constant: for each protected root — the checkout the process
    # loads from, the runner gem's, RHO_HOME, each resolved — `write|edit` on the root and
    # under it (the tools' `path`), and a command that NAMES the root, refused whole with
    # the shared sentence. The command glob is a substring on purpose: a command cannot be
    # path-precise, and a read of its own source goes through `read`/`grep`, which no rule
    # touches. What a raw-input glob does not promise — a relative spelling resolved under
    # the tools root, a symlink, `~`, `$RHO_HOME` — the person tightens with their own
    # rules. A deny binds under every mode; the allow rule above is inert beside it, because
    # deny wins wherever it sits in the list.
    INCUBATION = "an agent never edits its own checkout or home; develop a successor as a separate install".freeze
    EDIT_TOOLS = "write|edit".freeze
    # THE PREFIX IS THE PROVENANCE RULE: an
    # announced entry named `mcp__<server>__<tool>` is a third party's
    # tool, whose text arguments rho can read off the SCHEMA it announced
    # — the local registry's entries and a remote runner's `served_tools`
    # both carry `input_schema` — and cannot name in the abstract.
    MCP_PREFIX = "mcp__".freeze

    # The text-shaped top-level properties of one announced entry, split
    # into the ones a deny can be derived from and the ones it cannot: the
    # kernel walks `path` as a DOTTED key path and refuses one with an
    # empty segment, so only a property whose name is ONE valid segment
    # (non-empty, no `.`) becomes a rule — `file.path` would yield a rule
    # that never matches, `.x` one the kernel REFUSES, and a refused rule
    # list costs the WHOLE declaration. `rho mcp` lists the skipped ones.
    DenyProperties = Data.define(:derivable, :skipped)

    # `entries` are announced entries (the announcement's hashes, or a
    # remote runner's served tools, string keys): for each `mcp__` one,
    # every text-shaped property — `type: string`, or `type: array` of
    # `string` items (the kernel reads a scalar Array as text joined by
    # one space) — under every root, ONE deny rule in the `bash` form.
    def self.self_modification_rules(roots, entries: [])
      Array(roots).flat_map do |root|
        [
          deny_rule(EDIT_TOOLS, "path", root),
          deny_rule(EDIT_TOOLS, "path", "#{root}/*"),
          deny_rule(GUARDED_TOOLS, "command", "*#{root}*"),
          *Array(entries).flat_map { |entry| mcp_deny_rules(entry, root) },
        ]
      end.freeze
    end

    def self.deny_properties(entry)
      hash = entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_s) : {}
      return DenyProperties.new(derivable: [], skipped: []) unless hash["name"].to_s.start_with?(MCP_PREFIX)

      properties = Hash.try_convert(Hash.try_convert(hash["input_schema"])&.fetch("properties", nil)) || {}
      texts = properties.select { |_name, spec| text_shaped?(spec) }.keys.map(&:to_s)
      derivable, skipped = texts.partition { |name| !name.empty? && !name.include?(".") }
      DenyProperties.new(derivable: derivable.freeze, skipped: skipped.freeze)
    end

    def self.mcp_deny_rules(entry, root)
      name = entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_s)["name"].to_s : ""
      deny_properties(entry).derivable.map { |property| deny_rule(name, property, "*#{root}*") }
    end
    private_class_method :mcp_deny_rules

    def self.text_shaped?(spec)
      spec = Hash.try_convert(spec)
      return false if spec.nil?
      return true if spec["type"] == "string"

      spec["type"] == "array" && Hash.try_convert(spec["items"])&.fetch("type", nil) == "string"
    end
    private_class_method :text_shaped?

    def self.deny_rule(tool, path, match)
      { "tool" => tool, "path" => path, "match" => match, "verdict" => "deny", "reason" => INCUBATION }.freeze
    end
    private_class_method :deny_rule

    # THE LIST A DECLARATION WRITES: the constant, then this install's
    # self-modification denies over the entries it declares, then the
    # session grants (`LoopRequest::Grant`) — LAST,
    # because deny wins wherever it sits; no roots and no grants is the
    # constant itself.
    def self.approval_rules(roots: [], entries: [], grants: [])
      return APPROVAL_RULES if Array(roots).empty? && Array(grants).empty?

      (APPROVAL_RULES + self_modification_rules(roots, entries: entries) + Array(grants)).freeze
    end

    # THE SAME LIST FOR A REQUEST LOOP (`rho relay`). A kernel
    # rule addresses the writer its `origin` names, `model` when unnamed
    # (`Executors::Rules#applies?`): every rule above guards the MODEL's
    # rows, and a relay's one step is the person's — `author`-origin,
    # granted by its origin unless a rule naming `author` says otherwise.
    # So the verb passes the list re-addressed, rule for rule: the same
    # denies, the same allows, the incubation denies with them — `rm -rf /`
    # relayed to rho's runner is refused by the same sentence `rho do`'s
    # model would read. A one-task loop has no model row for the original
    # list to guard, so nothing is lost by the re-address.
    REQUEST_ORIGIN = "author".freeze

    def self.request_rules(roots: [], entries: [])
      approval_rules(roots: roots, entries: entries).map { |rule| rule.merge("origin" => REQUEST_ORIGIN).freeze }.freeze
    end

    # THE GUIDELINE: how to use the tools together, and what the kernel's delivered answers
    # are. Runner-independent, so it is rho's `system_prompt` slot on its profile — written
    # at boot beside the declaration (`Bindings#declare`) and compiled by the kernel as the
    # first system-role item of every assembled turn, inside the stable prefix. The
    # per-request lead below is developer-role and carries only what changes per turn or per
    # runner. The one other reader is the STANDALONE seed (`instructions`): a standalone
    # loop passes no assembler and reads no slot until the kernel's assembly compiler. The
    # runner facts that left the kernel's `task` bytes live here under rho's OWN names — a
    # file or a few greps are your own work, a process is for a server — style-neutral: the
    # slot is written once per boot and never rendered under an alias, so it names no kernel
    # tool a preset re-spells ("another agent", never `task`/`Agent`).
    GUIDELINE = <<~TEXT.strip.freeze
      You can call several tools in one message. When the calls do not depend on each other — reading three files, grepping, running a test and a linter — put them all in ONE message; they run at the same time and you get every result together. A file, or two or three greps, is your own work: call `read`/`grep` yourself, several in one message, rather than handing them to another agent. `start_process` is for a server or watcher the person operates, never for a command whose result you need — run that with `bash`. Results that arrive as `<task_result>` or `<answer>` blocks are the kernel delivering previously accepted work; they are not the person, so do not thank or answer them — act on them. Give parallel tasks that edit files disjoint files.

      #{ExecutionPolicy::PROMPT}

      For implementation work, first finish the smallest usable result, including requested supporting files and run instructions. Preserve a working entry point while improving it: create and check new dependencies before changing the entry point to reference them. Avoid replacing a working implementation merely to reorganize it. When a time budget is supplied, pass the same deadline and deliverables to delegated work and reserve time for verification and the final report. Run the checks relevant to the changes with the tools actually available; inspect rendered pages when browser tools are available. Report what you verified and what remains unverified. A successful file write alone does not prove that the result works.

      #{MemoryPolicy::PROMPT}
    TEXT

    # THE ROSTER'S HEADING: ONE neutral line naming the `agent` ARGUMENT — a parameter name,
    # never a kernel tool a preset re-spells (the guideline's own discipline) — over one
    # line per agent in claude-code's `formatAgentLine` shape with our address word.
    # Rendered INTO rho's `system_prompt` slot beside the guideline at the declare edge:
    # present on every runner, local or remote, stable per boot, inside the cached prefix.
    # No model on a line: neither reference prints it and the reader cannot override the
    # answerer's model selection.
    ROSTER_HEADING = "Agents here you can hand work to by @handle (the `agent` argument of a spawn or a send); " \
                     "each starts with an empty context, answers with its own tools, and reports back to you:".freeze
    ROSTER_NONE = "none".freeze

    module_function

    # THE DERIVED DECLARATION: a
    # named definition's seven columns are THIS declaration narrowed —
    # ONE implementation per mechanism. The universe is `parent`'s
    # `tool_definitions` MINUS `agent_names` (every name announced on
    # rho's AGENT address: the kernel addresses an agent-served call by
    # the DECLARING profile's address, and a named row has none —
    # `tool_not_served` at start); `definition.tools` is an EXACT
    # allowlist over it, kernel names included (absent → the whole
    # universe; `[]` → none; a name the universe does not hold is dropped
    # and logged `agents.skipped_tool`). The mode and the rules are the
    # parent's WHOLE list — a file cannot widen the posture; the
    # mechanism is `default` unless the definition supplies an assembly
    # template; a `delegate` compaction policy lowers to
    # the kernel's (the delegate summarizer is announced on the parent's
    # agent address); `default_model` is the file's `model`,
    # never the parent's preset (an unnamed model means the initiator's).
    # `fallback_model` PAIRS WITH THE MODEL IT BACKS: a file that names no
    # `model` runs on the initiator's line and inherits the parent's
    # fallback; one that names its own model declares its own
    # `fallback_model` or none, the parent's having been chosen for the
    # parent's model. A file's own `fallback_model` is its word either way.
    def derived_declaration(parent, definition, agent_names: [], log: nil)
      universe = Array(parent.fetch(:tool_definitions)).reject do |entry|
        Array(agent_names).include?(entry.dig("function", "name"))
      end
      {
        tool_definitions: narrow_universe(universe, definition, log),
        approval_mode: parent.fetch(:approval_mode),
        approval_rules: parent.fetch(:approval_rules),
        prompt_mechanism: definition.prompt_template ? "assembly" : "default",
        prompt_template: definition.prompt_template,
        compaction_policy: derived_compaction(parent.fetch(:compaction_policy)),
        default_model: definition.model,
        fallback_model: definition.fallback_model || (parent.fetch(:fallback_model) if definition.model.nil?),
      }
    end

    def narrow_universe(universe, definition, log)
      return universe if definition.tools.nil?

      held = universe.map { |entry| entry.dig("function", "name") }
      (definition.tools - held).each { |tool| log&.warn("agents.skipped_tool", path: definition.path, tool: tool) }
      universe.select { |entry| definition.tools.include?(entry.dig("function", "name")) }
    end

    def derived_compaction(policy)
      return policy unless policy["mode"] == "delegate"

      policy.except("tool_name").merge("mode" => "kernel")
    end

    # THE ROSTER: one line per row — `{handle:, description:,
    # tool_names:}` — under the heading, the stored names sorted, `none`
    # for an empty set; nil for no rows.
    def roster(rows)
      return nil if Array(rows).empty?

      lines = Array(rows).map do |row|
        names = Array(row.fetch(:tool_names)).sort
        "- @#{row.fetch(:handle)}: #{row.fetch(:description)} (tools: #{names.empty? ? ROSTER_NONE : names.join(", ")})"
      end
      [ROSTER_HEADING, *lines].join("\n")
    end

    # The shared policy and roster are stable across the parent and its side.
    # The template carries the current execution's kind after inherited history.
    def guideline_slot(roster)
      [GUIDELINE, roster].compact.join("\n\n")
    end

    # `registry` is the extension plane's; `model` is "provider/ref". One
    # model step, placed first: the seed of a standalone loop, and the
    # loop's answer until something is placed after it. `served` is a
    # runner ELSEWHERE's announced list: the seed then carries
    # that runner's entries in place of this machine's, and the caller
    # hands the runner's snapshot as `instructions` (`remote_instructions`).
    def steps(prompt:, model:, registry:, environment: nil, instructions: nil,
              kernel_tools: [], key: "work", served: nil, prompt_mechanism: nil, hints: [])
      # The environment leads and rides even under caller instructions; it is
      # in `instructions`, not the prompt, because compaction cannot summarize
      # it away. An extension's paragraph joins last.
      # Under `raw` (the unnamed default) the system field closes with the
      # guideline; under an ASSEMBLED word the seed carries no
      # system field at all — the kernel refuses `instructions` by name and
      # compiles the guideline from rho's `system_prompt` slot; the lead
      # rides in the prompt (`led`). `hints` are the model row's lines.
      guidance = assembled?(prompt_mechanism) ? "" :
        self.instructions(registry: registry, environment: environment, instructions: instructions, hints: hints)
      # The runner's tools, then the kernel's: the block heads the cached
      # prefix, so a local addition must not move the kernel's bytes, which
      # are fetched, never composed (`kernel_tool_redefined` otherwise).
      tools = tool_entries(served || announcement(registry: registry)) + Array(kernel_tools)
      [CybrosAgent::Steps::Model.new(
        prompt: prompt.to_s, key: key, model: { "model" => model.to_s },
        instructions: (guidance unless guidance.empty?), tools: (tools unless tools.empty?)
      )]
    end

    # THE SHELL'S ASSEMBLED WORDS: under either the kernel
    # compiles the standalone seed — the creator's slots, the room's
    # memory, the words — and the shell admits one text, the seed's prompt.
    ASSEMBLED_MECHANISMS = %w[default assembly].freeze

    def assembled?(mechanism) = ASSEMBLED_MECHANISMS.include?(mechanism.to_s)

    # THE ASSEMBLED SEED'S WORDS: the lead — the environment block and the
    # tool lines, or the caller's words in their place — AHEAD of the
    # person's words in the input block, the one text the shell admits.
    # In the sealed seed it survives compaction as the guideline does (a
    # repaired round re-reads round one's body); a moved root still
    # reaches the model. An empty lead sends the words alone.
    def led(lead, prompt) = [lead.to_s, prompt.to_s].reject(&:empty?).join("\n\n")

    # THE DEVELOPER-ROLE LEAD a conversation turn opens with:
    # the environment block, then the tool lines — what changes per turn
    # and per runner — or the caller's own words in their place; behind
    # history and outside the stable prefix, where the kernel seals it with
    # the turn, so a moved root or a changed tool set appends a new lead
    # and never busts the cached slots or the history before it. The guideline is the
    # profile's slot. Empty when there is nothing to say, and an empty
    # lead sends no inline entry.
    # `hints` are the turn row's `lead_hints` texts (the row's per-request lines for the model):
    # appended AFTER the tool lines — developer-role, per request, outside
    # the stable prefix — and never in the profile's slot.
    def lead(registry:, environment: nil, instructions: nil, hints: [])
      [
        environment && environment_block(registry, environment),
        instructions || tool_lines(registry),
        hint_block(hints),
      ].compact.join("\n\n")
    end

    # THE STANDALONE SEED'S SYSTEM FIELD: today's whole text — the conversation lead's
    # bytes, then the guideline (or the caller's words in place of both) — because a
    # standalone loop has no slot reader until the kernel's assembly compiler. The one place
    # the constant is read twice. The hints ride after the tool lines, ahead of the
    # guideline.
    def instructions(registry:, environment: nil, instructions: nil, hints: [])
      lines = tool_lines(registry)
      guidance = instructions ? [instructions, hint_block(hints)] :
        [lines, hint_block(hints), (ExecutionPolicy.context(kind: "standalone") if lines), lines && GUIDELINE]
      [
        environment && environment_block(registry, environment),
        *guidance,
      ].compact.join("\n\n")
    end

    # THE HINT BLOCK: one line per hint, the row's own bytes verbatim; no
    # hint, no block.
    def hint_block(hints)
      lines = Array(hints).map(&:to_s).reject(&:empty?)
      lines.empty? ? nil : lines.join("\n")
    end

    # Each provider states the environment its own tools are bound to;
    # nothing here interprets it, and no provider saying anything authors
    # no block at all.
    def environment_block(registry, environment)
      fragments = registry.environment_fragments(environment)
      return nil if fragments.empty?

      fragments.map { |fragment| fragment.fetch("text") }.join("\n\n")
    end

    # THE LEAD FOR A RUNNER ELSEWHERE: the
    # announced environment is a SNAPSHOT — placement plus what the runner
    # said at its last announcement — so this renders the snapshot's
    # fragments ALONE, or the caller's own words. No per-tool lines (the
    # descriptions ride the schema the model reads), no guideline (the
    # profile's slot). A runner that announced no fragment has no lead:
    # the empty string, which sends no inline entry.
    # `root`/`directories`: a conversation's
    # BOUND root set on a runner elsewhere, named ahead of the snapshot —
    # the snapshot describes that runner's default root; the runner's own
    # resolution shows on its first result.
    def remote_lead(environment, instructions: nil, hints: [], root: nil, directories: [])
      [bound_block(root, directories), (snapshot_block(environment) if snapshot_block(environment) != ""), instructions,
       hint_block(hints)].compact.join("\n\n")
    end

    # THE BOUND ROOT'S LINE for a runner elsewhere: model-facing, one
    # sentence, the directories after it; nil with no binding.
    BOUND_ROOT = "This conversation's root is %s; relative paths resolve against it there.".freeze
    ADDITIONAL_DIRECTORIES = "Additional directories: %s".freeze

    def bound_block(root, directories)
      return nil if root.nil?

      lines = [format(BOUND_ROOT, root)]
      lines << format(ADDITIONAL_DIRECTORIES, Array(directories).join(", ")) unless Array(directories).empty?
      lines.join("\n")
    end

    # THE STANDALONE SEED'S SYSTEM FIELD on a runner elsewhere: the
    # snapshot's fragments, then the guideline or the caller's own words —
    # today's bytes, for the same reason `instructions` keeps them; the
    # hints between the snapshot and the guideline.
    def remote_instructions(environment, instructions: nil, hints: [])
      [(snapshot_block(environment) if snapshot_block(environment) != ""),
       *(instructions ? [instructions, hint_block(hints)] :
         [hint_block(hints), ExecutionPolicy.context(kind: "standalone"), GUIDELINE])].compact.join("\n\n")
    end

    def snapshot_block(environment)
      fragments = Array(Hash.try_convert(environment)&.fetch("fragments", nil))
      fragments.filter_map { |fragment| Hash.try_convert(fragment)&.fetch("text", nil) }.join("\n\n")
    end

    # The keywords `client.profile.declare_configuration` takes, whole: an
    # empty set declares no tools, which the kernel reads as none.
    # `compaction` is the policy the settings resolved — the kernel's, or
    # rho's own summarizer by name (`Rho::Config#compaction_policy`).
    # `remote` is the announced list of every runner bound to a host this
    # daemon follows or selected in its settings: the profile
    # declares the UNION — this machine's entries first, then each
    # runner's in the order given, first bytes winning — and each turn is
    # narrowed to its own runner's names by `tool_names`. `roots` are the
    # install's protected roots (`Rho.protected_roots`): the
    # self-modification denies ride behind the constant when given.
    # `default_model` is the settings' — rho's OWN
    # model, written to the profile as its `default_model` fact so the
    # kernel answers every turn addressed to rho on it before the
    # initiator's; nil declares none (the initiator's model then governs).
    # `fallback_model` is the settings' too — the model the kernel re-runs
    # a step rho answers on once when a provider's classifier declined it
    # or the provider was overloaded on every attempt; nil declares none,
    # and such a step then fails `model_refused` or `provider_overloaded`.
    # `grants` are the session's allow rules, the
    # daemon's own, appended last. `extras` are the agent
    # slot's per-conversation entries beyond the registry's — the union
    # declares them beside this machine's own, so the digest gate moves
    # when a set moves: THE COST, accepted and stated, is that a
    # re-declaration rewrites the profile's `tool_definitions`; a live
    # turn's prompt bytes move only where its OWN names' definitions
    # changed, and an editor's servers land in that editor's
    # conversation's names alone.
    def declaration(registry:, kernel_tools: [], compaction: Rho::Config::DEFAULTS.fetch("compaction"), remote: [],
                    roots: [], default_model: nil, grants: [], extras: [], lifecycle_hooks: nil, fallback_model: nil)
      announced = announcement(registry: registry, extras: extras)
      machine = union([tool_entries(announced), *Array(remote).map { |served| tool_entries(served) }])
      {
        tool_definitions: machine.entries + Array(kernel_tools),
        approval_mode: APPROVAL_MODE,
        # The list is a constant of this version plus this install's roots
        # over what it declares (the `mcp__` denies read the announced
        # schemas, local and remote) plus the session's grants: it rides
        # every write, and the constant half lands at the next boot.
        approval_rules: approval_rules(roots: roots,
          entries: [announced, *Array(remote)].flat_map { |served| served_entries(served) }, grants: grants),
        prompt_mechanism: PROMPT_MECHANISM,
        prompt_template: PROMPT_TEMPLATE,
        compaction_policy: compaction,
        default_model: default_model,
        lifecycle_hooks: lifecycle_hooks,
        fallback_model: fallback_model,
      }
    end

    # WHAT A MODEL IS OFFERED from ONE announced list — the shape the
    # kernel stores (`name`, `effect_profile`, `timeout_ms?`,
    # `description?`, `input_schema?`; `announcement` below renders it,
    # discovery reads it back) — minus the one the kernel addresses by the
    # profile's policy NAME (the delegate summarizer): announced,
    # never declared, so a model cannot call it even by guessing (the door
    # admits only declared names). The lowering reads the kernel's
    # `input_schema` spelling and sorts by name, so the bytes are the
    # registry's own declarations' bytes, whichever feeder handed the list.
    def tool_entries(served)
      offered = served_entries(served).reject { |tool| undeclared.include?(tool.fetch("name")) }
      CybrosAgent::Api::ToolLowering.function_entries(offered)
    end

    # THE NAMES NO MODEL IS OFFERED, whichever list served them: the delegate summarizer the kernel addresses by policy name,
    # the runner capabilities a PERSON requests through the
    # relay — a file's bytes, a process's log — and the runner's `skill`:
    # the KERNEL's tool of that name is what a
    # profile declares and a model calls; the runner's announced `skill` is
    # where the kernel delivers a load of a name the runner announced under
    # `documents`, hidden here so the two never meet at compile
    # (`duplicate_tool_name`). The checkpoint store's two: `world_restore` — no model rewinds its own world; a
    # member reaches it through a request loop (`rho rewind`) — and the
    # `checkpoints` read, the SDK's cache miss and a person's diff. By
    # NAME, because the list may come from a runner elsewhere through
    # discovery, whose classes this daemon never loaded; the runner
    # announces the five without a description or a schema besides
    # (`announcement`), so no peer can author a declaration from them
    # either.
    # The seventh: `environment_bind`, the
    # relay's way of telling a runner elsewhere a conversation's root set.
    def undeclared
      [Extensions::Compaction::TOOL_NAME, Rho::Runner::Tools::FilesBytes::NAME,
       Extensions::Processes::Tools::ProcessLog::NAME, Rho::Runner::Tools::Skill::NAME,
       Rho::Runner::Tools::Checkpoints::NAME, Rho::Runner::Tools::WorldRestore::NAME,
       Extensions::Environment::Tools::Bind::NAME].freeze
    end

    # The two feeders' one shape: the announcement hash as rendered here
    # (string keys), or the SDK's discovery projection (`ServedTool`, a
    # Data whose `to_h` answers symbol keys).
    def served_entries(served)
      Array(served).map do |entry|
        hash = entry.respond_to?(:to_h) ? entry.to_h : Hash.try_convert(entry)
        raise ArgumentError, "a served entry must be a Hash or a ServedTool, got #{entry.class}" if hash.nil?

        hash.transform_keys(&:to_s)
      end
    end

    # THE UNION over lowered entry lists: one entry per name,
    # the FIRST bytes winning in the order given — this machine's, then
    # each remote runner's — a differing second REPORTED by name and never
    # carried (`Nexus::ToolDeclarations.canonical` refuses no duplicate,
    # so two readings of one name must never both enter the profile), and
    # the answer canonical by name, the bytes the kernel stores.
    Union = Data.define(:entries, :conflicts)

    def union(lists)
      kept = {}
      conflicts = []
      Array(lists).flatten(1).each do |entry|
        name = entry.dig("function", "name")
        if kept.key?(name)
          conflicts << name unless kept.fetch(name) == entry
        else
          kept[name] = entry
        end
      end
      Union.new(entries: kept.values.sort_by { |entry| entry.dig("function", "name") }, conflicts: conflicts.uniq)
    end

    # THE COLLISION CHECK a handoff runs BEFORE the bind: the candidate's
    # names the base already holds in OTHER bytes — the tools a handoff
    # would offer the model two readings of.
    def conflicts(base, candidate)
      held = Array(base).to_h { |entry| [entry.dig("function", "name"), entry] }
      Array(candidate).filter_map do |entry|
        name = entry.dig("function", "name")
        name if held.key?(name) && held.fetch(name) != entry
      end.uniq
    end

    # ONE DIGEST per set of declared bytes, order-blind: what decides
    # whether the profile is written again — a re-declaration moves every
    # cached prefix the profile's hosts share, so it happens only when the
    # union CHANGES.
    def digest(entries)
      canonical = Array(entries).sort_by { |entry| [entry.dig("function", "name").to_s, JSON.generate(entry)] }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    # WHAT THIS MACHINE SERVES, for
    # `executor.announce(tools:)`: this machine's tools alone — the kernel's
    # own names are never rho's to announce — each with its DESCRIPTION,
    # SCHEMA and EFFECT_PROFILE constants, sorted by name. The declaration
    # facts ride in the kernel's spelling (`input_schema` beside
    # `effect_profile`; the MCP `inputSchema` stays on `declaration`, the
    # lowering's input — one entry, two renderings, the same bytes) so an
    # agent that did not load this registry can author a declaration from
    # what the kernel stored. A tool that declares `TIMEOUT_MS` announces it
    # (the delegate summarizer does — its park bounds a dead rho's cost to
    # the kernel's fallback); the rest announce none (`bash`'s bound is the
    # runner's setting, honoured under the park) and the kernel falls to its
    # default. The declaration above is the model's fact; this is the
    # kernel's, computed from the same registry by a second call.
    # An entry described to nobody (`Entry#undescribed?`) announces its
    # name, profile and park alone: served, never authorable by a peer.
    # THE RENDERER IS THE REGISTRY'S (`Registry#announcement`):
    # moved down so rho's daemon and the harness executor render one
    # shape from one method; the bytes are pinned identical to the six
    # lines that stood here.
    # `extras`: the AGENT slot's entries
    # beyond the registry's — every anchor's editor servers, as the
    # daemon's servers table renders them (`Entry#announcement`) — a name
    # once with the registry's bytes winning, sorted by name as the
    # registry's own list is. None: the registry's list to the byte.
    def announcement(registry:, extras: [])
      announced = registry.announcement
      return announced if Array(extras).empty?

      names = announced.to_set { |entry| entry.fetch("name") }
      (announced + Array(extras).reject { |entry| names.include?(entry.fetch("name")) })
        .sort_by { |entry| entry.fetch("name") }
    end

    # THE ENVIRONMENT THIS MACHINE'S TOOLS ARE BOUND TO, for
    # `executor.announce(environment:)`: the ROOT's facts — what `rho env`
    # shows, minus its daemon-UI `source` — and every provider's fragment,
    # the same text `environment_block` renders into a lead here. Announced
    # at placement and again on `rho env`, so a remote reader holds a
    # snapshot; the per-request lead stays live. Opaque to the kernel.
    # `booted_at` is this daemon's boot
    # instant — the runner's PROCESS LIFE, constant across `rho env`
    # re-points — the key a host elsewhere re-asserts a conversation's
    # root set on; a runner announcing none announces no key, which
    # `TreeSync` reads as unknown, never different.
    def environment_document(registry:, environment:, booted_at: nil)
      {
        "root" => environment.root,
        "branch" => environment.branch,
        "worktree" => environment.worktree,
        "platform" => environment.platform,
        "booted_at" => booted_at,
        "fragments" => registry.environment_fragments(environment),
      }.compact
    end

    # THE DOCUMENTS THIS MACHINE CAN LOAD FOR A MODEL, for `executor.announce(documents:)`: every provider's `{name,
    # description}` entries over the ROOT's environment — the Coding
    # extension's scan of the checkout's skill directories — announced
    # beside the list and the environment document, at placement and again
    # on `rho env`, so a changed checkout re-announces on the next root
    # move, `rho env` or boot; never per round. The kernel merges them into
    # the turn's skill catalog and routes a load of a name here to this
    # runner's `skill`.
    def documents(registry:, environment:)
      registry.documents(environment)
    end

    # THE TOOL LINES: each tool's declared snippet and guidelines, assembled
    # into the section a model reads beside the schemas — per-runner, so
    # they ride the per-request lead, never the profile's slot; no snippet,
    # no block at all.
    def tool_lines(registry)
      fragments = registry.prompt_fragments
      return nil if fragments.empty?

      lines = ["You are working on the operator's own machine through these tools:"]
      fragments.sort_by { |fragment| fragment.fetch("name") }.each do |fragment|
        lines << "- #{fragment.fetch("name")}: #{fragment.fetch("snippet")}"
      end
      guidelines = fragments.flat_map { |fragment| Array(fragment["guidelines"]) }.uniq
      unless guidelines.empty?
        lines << ""
        lines << "Guidelines:"
        guidelines.each { |guideline| lines << "- #{guideline}" }
      end
      lines.join("\n")
    end
  end
end

require_relative "loop_request/grant"
