require "digest"
require "json"
require_relative "execution_policy"
require_relative "memory_policy"
require_relative "code_mode"

module Rho
  # What rho declares to its profile and when it starts work: kernel names,
  # candidate Runners, Runner tool selection and Agent-provided tools or aliases.
  # Nexus imports the selected Runner's tools at creation and freezes their
  # targets and schemas. Announcements here also supply rho's approval policy;
  # candidate schemas never become an Agent-authored tool union.
  module RunDeclaration
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
    # Keep changing skills and execution facts after history. Stable slots
    # and the already accepted transcript remain reusable across Runner changes.
    PROMPT_TEMPLATE = { "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "slot", "slot" => "character" },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" }, { "type" => "history" }, { "type" => "skills" },
      { "type" => "lead" }, { "type" => "tail" },
      ExecutionPolicy.context_block, { "type" => "input" },
    ] }.freeze

    # The two tools that run a command, in the rule grammar's `|` spelling
    # (`Extensions::Guard::GUARDED_TOOLS` is the runner's array of the same
    # fact; the test cross-pins them).
    GUARDED_TOOLS = "bash|start_process".freeze

    # THE RUNNER'S READS: read-only by construction —
    # each declares `kind: read_only, destructive: false, effect_scope: closed`
    # (`rho-runner/lib/rho/runner/tools/{read,grep,ls,find}.rb`,
    # `extensions/processes/tools.rb` READ_PROFILE) — so `ask` means "ask
    # before an EFFECT", as every reference does (claude-code
    # `FileReadTool.isReadOnly`, codex's auto-approved read-only commands,
    # opencode `read: allow`). `bash` stays a command (a `cat` is not a
    # read tool); the memory reads are the kernel's, inside `memory_*`.
    # Inert under `bypass`; a deny still wins wherever it sits. The test
    # cross-pins the list against the registry's effect profiles.
    #
    # THE MEMBERSHIP RULE: a `read_only` tool with
    # `effect_scope: closed` — a read of this machine — is named here; a
    # `read_only` tool with `effect_scope: open` (such as `web_fetch`)
    # is NEVER named here — it runs under `bypass`, parks under
    # `ask` and is refused under `rules` until a rule allows it; and it
    # gets NO ask row of its own, because the evaluator collects every
    # matching rule with `ask` beating `allow`, so an ask row on the tool
    # would defeat every per-host allow — the operator's and the grant
    # verb's — and park it forever.
    READ_ONLY_TOOLS = "read|grep|ls|find|file_import|file_publish|read_process|list_processes|read_schedules|list_extensions".freeze

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
      *deny_rules("elevation is not available to an unattended run",
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
      { "tool" => "memory_*|ask|delegate_task|code|tool_search|tool_call|runners_list|skill|todo_write|session_search|session_read", "verdict" => "allow" }.freeze,
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
    INCUBATION = "direct installation edits are disabled; use managed extensions or develop a separate rho successor".freeze
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
    # Managed package selection has its own explicit write tool and lifecycle.
    # These rules continue to deny direct file/shell edits to the installation.
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
    # session grants (`RunDeclaration::Grant`) — LAST,
    # because deny wins wherever it sits; no roots and no grants is the
    # constant itself. Several Runners can announce the same MCP tool: keep
    # each exact rule once, at its first position, without merging distinct
    # reasons or origins.
    def self.approval_rules(roots: [], entries: [], grants: [], guard: true)
      return Array(grants).freeze unless guard
      return APPROVAL_RULES if Array(roots).empty? && Array(grants).empty?

      (APPROVAL_RULES + self_modification_rules(roots, entries: entries) + Array(grants)).uniq.freeze
    end

    # THE SAME LIST FOR A REQUEST RUN (`rho call_tool`). A kernel
    # rule addresses the writer its `origin` names, `model` when unnamed
    # (`Executors::Rules#applies?`): every rule above guards the MODEL's
    # rows, and a call_tool's one step is the person's — `author`-origin,
    # granted by its origin unless a rule naming `author` says otherwise.
    # So the verb passes the list re-addressed, rule for rule: the same
    # denies, the same allows, the incubation denies with them — `rm -rf /`
    # relayed to rho's runner is refused by the same sentence `rho do`'s
    # model would read. A one-task run has no model row for the original
    # list to guard, so nothing is lost by the re-address.
    REQUEST_ORIGIN = "author".freeze

    def self.request_rules(roots: [], entries: [], guard: true)
      approval_rules(roots: roots, entries: entries, guard: guard).map { |rule| rule.merge("origin" => REQUEST_ORIGIN).freeze }.freeze
    end

    # THE GUIDELINE: how to use the tools together, and what the kernel's delivered answers
    # are. Runner-independent, so it is rho's `system_prompt` slot on its profile — written
    # at boot and after Settings changes (`Bindings#declare`) and compiled by the kernel as the
    # first system-role item of every assembled turn, inside the stable prefix. The
    # per-request lead below is developer-role and carries only what changes per turn or per
    # runner. The one other reader is the STANDALONE seed (`instructions`): a standalone
    # run passes no assembler and reads no slot until the kernel's assembly compiler. The
    # runner facts that left the kernel's `task` bytes live here under rho's OWN names — a
    # file or a few greps are your own work, a process is for a server — style-neutral: the
    # slot is never rendered under an alias, so it names no kernel
    # tool a preset re-spells ("another agent", never `task`/`Agent`).
    GUIDELINE = <<~TEXT.strip.freeze
      Some tool schemas are available through tool discovery. Find the capability you need, then invoke the exact returned callable with the tool invocation tool or from code when available. Choose an environment when creating work; an omitted choice inherits the parent's environment. Each accepted task keeps its environment and tool authority, and code or delegated work inherits that frozen surface. Different tasks in one run can use different explicitly selected environments. Inspect available Runners before creating work elsewhere. A person's default Runner change affects future work only. Discovery does not grant new tools or change an accepted target.

      You can call several tools in one message. When the calls do not depend on each other — reading three files, grepping, running a test and a linter — put them all in ONE message; they run at the same time and you get every result together. A file, or two or three greps, is your own work: call `read`/`grep` yourself, several in one message, rather than handing them to another agent. `start_process` is for a server or watcher the person operates, never for a command whose result you need — run that with `bash`. Results that arrive as `<task_result>` or `<answer>` blocks are the kernel delivering previously accepted work; they are not the person, so do not thank or answer them — act on them. Give parallel tasks that edit files disjoint files.

      #{ExecutionPolicy::PROMPT}

      For implementation work, first finish the smallest usable result, including requested supporting files and run instructions. Preserve a working entry point while improving it: create and check new dependencies before changing the entry point to reference them. Avoid replacing a working implementation merely to reorganize it. When a time budget is supplied, pass the same deadline and deliverables to delegated work and reserve time for verification and the final report. Run the checks relevant to the changes with the tools actually available; inspect rendered pages when browser tools are available. Report what you verified and what remains unverified. A successful file write alone does not prove that the result works.

      #{MemoryPolicy::PROMPT}
    TEXT

    # THE ROSTER'S HEADING: ONE neutral line naming the `agent` ARGUMENT — a parameter name,
    # never a kernel tool a preset re-spells (the guideline's own discipline) — over one
    # line per agent in claude-code's `formatAgentLine` shape with our address word.
    # Rendered in the turn's lead after history. Tool schemas are discovered
    # separately, so changes to a definition's callable set do not rewrite it.
    # No model on a line: neither reference prints it and the reader cannot override the
    # answerer's model selection.
    ROSTER_HEADING = "Agents here you can hand work to by @handle (the `agent` argument of a spawn or a send); " \
                     "each starts with an empty context, answers with its own tools, and reports back to you:".freeze

    module_function

    # Named Agents narrow the same source intentions. They have no application
    # address, so Agent-only callables stay out; a Runner serving the same name
    # remains selectable independently. Catalog names distinguish kernel calls
    # from Runner served names without copying either source's schemas.
    # The parent's approval posture and any Runner allowlist remain the floor.
    def derived_declaration(parent, definition, agent_names: [], kernel_tool_names: {}, runner_names: [], log: nil)
      universe = Array(parent.fetch(:tool_definitions)).reject do |entry|
        agent_names.include?(entry.dig("function", "name")) && !entry.key?("canonical")
      end
      kernels = parent.fetch(:kernel_tools)
      kernel_names = kernels.flat_map { |canonical| [canonical, kernel_tool_names[canonical]].compact }
      custom_names = parent.fetch(:tool_definitions).map { |entry| entry.dig("function", "name") }
      known_kernel_names = kernel_tool_names.keys + kernel_tool_names.values + kernel_names +
        parent.fetch(:tool_definitions).filter_map { |entry| entry["canonical"] }
      selected_runners = derived_runner_tool_names(parent, definition.tools,
        other_names: known_kernel_names + custom_names + agent_names, runner_names: runner_names)
      if definition.tools
        held = kernel_names + universe.flat_map { |entry| [entry.dig("function", "name"), entry["canonical"]].compact } + Array(selected_runners)
        (definition.tools - held).each { |tool| log&.warn("agents.skipped_tool", path: definition.path, tool: tool) }
      end
      {
        tool_definitions: narrow_universe(universe, definition),
        kernel_tools: definition.tools.nil? ? kernels : kernels.select { |canonical|
          definition.tools.include?(canonical) || definition.tools.include?(kernel_tool_names[canonical])
        },
        runner_executor_public_ids: parent.fetch(:runner_executor_public_ids),
        runner_tool_names: selected_runners,
        approval_mode: parent.fetch(:approval_mode),
        approval_rules: parent.fetch(:approval_rules),
        prompt_mechanism: definition.prompt_template ? "assembly" : "default",
        prompt_template: definition.prompt_template,
        compaction_policy: derived_compaction(parent.fetch(:compaction_policy)),
        default_model: definition.model,
        fallback_model: definition.fallback_model || (parent.fetch(:fallback_model) if definition.model.nil?),
      }
    end

    def narrow_universe(universe, definition)
      return universe if definition.tools.nil?

      universe.select do |entry|
        definition.tools.include?(entry.dig("function", "name")) || definition.tools.include?(entry["canonical"])
      end
    end

    def derived_runner_tool_names(parent, tools, other_names:, runner_names:)
      allowed = parent.fetch(:runner_tool_names)
      return allowed if tools.nil?
      return [] if parent.fetch(:runner_executor_public_ids).empty?

      selected = tools.reject { |name| other_names.include?(name) && !runner_names.include?(name) } - undeclared
      allowed.nil? ? selected : selected & allowed
    end

    def derived_compaction(policy)
      return policy unless policy["mode"] == "delegate"

      policy.except("tool_name").merge("mode" => "kernel")
    end

    # One line per address and description. Tool authority stays in each
    # definition's configuration and is never copied into this prompt roster.
    def roster(rows)
      return nil if Array(rows).empty?

      lines = Array(rows).map do |row|
        "- @#{row.fetch(:handle)}: #{row.fetch(:description)}"
      end
      [ROSTER_HEADING, *lines].join("\n")
    end

    # Nexus supplies the selected environment. rho adds only its own dynamic
    # instructions and Agent roster after history.
    def execution_lead(lead, roster: nil)
      [lead, roster]
        .compact.reject(&:empty?).join("\n\n")
    end

    # A standalone seed carries the same source intentions as the profile.
    # `served` describes the selected remote Runner only for application policy;
    # Nexus owns importing its schemas. Raw callers retain their instructions.
    def steps(prompt:, model:, registry:, environment: nil, instructions: nil, system_prompt: GUIDELINE,
              kernel_tools: [], kernel_aliases: [], runner_executor_public_ids: [], runner_tool_names: nil,
              key: "work", served: nil, prompt_mechanism: nil, hints: [], code_mode: true, runner_executor_public_id: nil)
      # The environment rides even under caller instructions; it is
      # in `instructions`, not the prompt, because compaction cannot summarize
      # it away. An extension's paragraph joins last.
      # Under `raw` (the unnamed default) the system field starts with the
      # guideline; under an ASSEMBLED word the seed carries no
      # system field at all — the kernel refuses `instructions` by name and
      # compiles the guideline from rho's `system_prompt` slot; the lead
      # rides in the prompt (`led`). `hints` are the model row's lines.
      guidance = assembled?(prompt_mechanism) ? "" :
        self.instructions(registry: registry, environment: environment, instructions: instructions,
          system_prompt: system_prompt, hints: hints, code_mode: code_mode)
      raise ArgumentError, "a served Runner list requires runner_executor_public_id" if served && runner_executor_public_id.nil?

      declared = declaration(registry: registry, kernel_tools: kernel_tools, kernel_aliases: kernel_aliases,
        runner_executor_public_ids: runner_executor_public_ids, runner_tool_names: runner_tool_names)
      tools = CodeMode.tools(declared.fetch(:tool_definitions), code_mode)
      allowed = declared.fetch(:runner_tool_names)
      unless code_mode
        offered = served || announcement(registry: registry.serving(:runner))
        allowed = (allowed || runner_model_tool_names(offered)) - ["code"]
      end
      [CybrosAgent::Steps::Model.new(
        prompt: prompt.to_s, key: key, model: { "model" => model.to_s },
        instructions: (guidance unless guidance.empty?), tools: (tools unless tools.empty?),
        kernel_tools: declared.fetch(:kernel_tools), runner_executor_public_ids: declared.fetch(:runner_executor_public_ids),
        runner_tool_names: allowed
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
    def lead(registry:, environment: nil, instructions: nil, hints: [], code_mode: true,
             kernel_environment: false, environment_snapshot: nil, root: nil, directories: [])
      [
        bound_block(root, directories),
        (environment_block(registry, environment, kernel_environment: kernel_environment, snapshot: environment_snapshot) if environment),
        instructions || tool_lines(registry, code_mode: code_mode),
        hint_block(hints),
      ].compact.join("\n\n")
    end

    # Raw seeds retain their environment in the system field across compaction.
    # Stable guidance precedes tool snippets, environment and per-model hints so
    # switching a Runner does not invalidate the beginning of that field.
    def instructions(registry:, environment: nil, instructions: nil, system_prompt: GUIDELINE, hints: [], code_mode: true)
      lines = tool_lines(registry, code_mode: code_mode)
      guidance = instructions ? [instructions] :
        [system_prompt, ExecutionPolicy.context(kind: "standalone"), lines]
      [
        *guidance,
        environment && environment_block(registry, environment),
        hint_block(hints),
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
    def environment_block(registry, environment, kernel_environment: false, snapshot: nil)
      fragments = registry.environment_fragments(environment)
      if kernel_environment
        # Repository instructions and the live editor port depend on this
        # conversation's root. The Runner's generic environment is Nexus's.
        held = Array(snapshot.to_h["fragments"]).map { |fragment| fragment["text"] }
        fragments = fragments.select { |fragment| fragment.fetch("extension") == Extensions::Conventions::NAME && !held.include?(fragment.fetch("text")) }
      end
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
    def remote_lead(environment, instructions: nil, hints: [], root: nil, directories: [], kernel_environment: false)
      snapshot = snapshot_block(environment) unless kernel_environment
      [bound_block(root, directories), (snapshot unless snapshot.to_s.empty?), instructions,
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
    # guideline or the caller's own words precede the snapshot and hints.
    # The environment stays in this system field across compaction.
    def remote_instructions(environment, instructions: nil, system_prompt: GUIDELINE, hints: [])
      [*(instructions ? [instructions] : [system_prompt, ExecutionPolicy.context(kind: "standalone")]),
       (snapshot_block(environment) if snapshot_block(environment) != ""), hint_block(hints)].compact.join("\n\n")
    end

    def snapshot_block(environment)
      fragments = Array(Hash.try_convert(environment)&.fetch("fragments", nil))
      fragments.filter_map { |fragment| Hash.try_convert(fragment)&.fetch("text", nil) }.join("\n\n")
    end

    # The complete execution configuration for `profile.declare_configuration`;
    # the daemon adds its owned prompt documents after resolving the roster.
    # An empty tool set declares no tools, which the kernel reads as none.
    # `compaction` is the policy the settings resolved — the kernel's, or
    # rho's own summarizer by name (`Rho::Config#compaction_policy`).
    # Candidate order comes from the caller, independently of cached discovery.
    # `remote` supplies announcement facts only for rho's approval rules.
    # `roots` supplies the install's self-modification deny rules.
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
    # slot's per-conversation entries beyond the registry's — the profile
    # declares them beside this machine's own, so the digest gate updates
    # the profile when authority changes. Deferred declarations stay out
    # of the provider prefix while Nexus imports the selected Runner's tools
    # at creation. An editor's servers land in that editor's
    # conversation's names alone.
    def declaration(registry:, kernel_tools: [], kernel_aliases: [], runner_executor_public_ids: [], runner_tool_names: nil,
                    compaction: { "mode" => "kernel" }, remote: [],
                    roots: [], default_model: nil, grants: [], extras: [], lifecycle_hooks: nil, fallback_model: nil, guard: true)
      agent = announcement(registry: registry.serving(:agent), extras: extras)
      own = announcement(registry: registry.serving(:runner))
      agent_entries = tool_entries(agent)
      extra_names = served_entries(extras).map { |entry| entry.fetch("name") } - registry.serving(:agent).names
      agent_entries = agent_entries.map do |entry|
        extra_names.include?(entry.dig("function", "name")) ? entry.merge("defer_loading" => true) : entry
      end
      entries = unique_entries([agent_entries, Array(kernel_aliases)])
      announced = [agent, own, *remote.map(&:served_tools)].flat_map { |served| served_entries(served) }
      rules = approval_rules(roots: roots, entries: announced, grants: grants, guard: guard)
      {
        tool_definitions: entries,
        kernel_tools: Array(kernel_tools),
        runner_executor_public_ids: runner_executor_public_ids,
        runner_tool_names: runner_tool_names && runner_tool_names - undeclared,
        approval_mode: APPROVAL_MODE,
        # The kernel resolves each callable to its served tool name before
        # approval. Rules name that wire tool, independent of Runner count.
        approval_rules: rules,
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
      offered = served_entries(served).reject do |tool|
        name = tool.fetch("name")
        undeclared.include?(name) || name == Rho::Runner::Tools::Skill::NAME
      end
      CybrosAgent::Api::ToolLowering.function_entries(offered).map do |entry|
        entry.dig("function", "name").start_with?(MCP_PREFIX) ? entry.merge("defer_loading" => true) : entry
      end
    end

    # Only names are needed to narrow application policy, such as code mode.
    # Operator capabilities remain excluded even if they supply model fields.
    def runner_model_tool_names(served)
      served_entries(served).filter_map do |entry|
        name = entry.fetch("name")
        name if entry["description"] && entry["input_schema"] && !undeclared.include?(name)
      end.uniq
    end

    # These capabilities are addressed by policy or operator tool calls, not
    # offered to a model: the compaction delegate, file/process inspection,
    # checkpoint inspection/restoration, and environment binding. Runner
    # skills are imported by Nexus from the selected Runner's announcement.
    def undeclared
      [Extensions::Compaction::TOOL_NAME, Rho::Runner::Tools::FilesBytes::NAME,
       Extensions::Processes::Tools::ProcessLog::NAME,
       Rho::Runner::Tools::Checkpoints::NAME, Rho::Runner::Tools::CheckpointRestore::NAME,
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

    # One Agent callable has one meaning. An accidental conflicting custom
    # tool or compact alias is an author bug.
    def unique_entries(lists)
      kept = {}
      Array(lists).flatten(1).each do |entry|
        name = entry.fetch("function").fetch("name")
        raise ArgumentError, "conflicting callable: #{name}" if kept.key?(name) && kept.fetch(name) != entry

        kept[name] = entry
      end
      kept.values.sort_by { |entry| entry.fetch("function").fetch("name") }
    end

    # One digest per complete authorized set, order-blind. Catalog refreshes
    # write only when these bytes change; deferred schemas are independently
    # omitted from provider-visible tools when discovery and invocation exist.
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
    def tool_lines(registry, code_mode: true)
      fragments = registry.prompt_fragments.uniq { |fragment| fragment.fetch("name") }
      fragments = fragments.reject { |fragment| fragment.fetch("name") == "code" } unless code_mode
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

require_relative "run_declaration/grant"
