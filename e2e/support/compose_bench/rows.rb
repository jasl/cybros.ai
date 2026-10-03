require_relative "../../../nexus/lib/nexus/tool_registry"
require_relative "../../../nexus/lib/nexus/compose"

module E2E
  module ComposeBench
    # THE TEXT ROWS. R-LADDER is the shipped `compose` description, read from the registry so the bench
    # measures the bytes a model really gets, under the id its bytes were measured as a variant; a
    # pair reads each row on its own tree, since a text is scored under the kernel it describes. A
    # re-cut is a row beside the shipped one: the same bytes with NAMED edits, each anchored on a
    # sentence of the shipped text so a moved anchor is an error and never a silent no-op, and the
    # harness test pins that the row's diff is exactly its edits.
    #
    # The shipped compose text says a step reads only the results it is handed and distinguishes the
    # call's boolean `wait` from the fan's success-count `until`. `LANDED` anchors the read clause,
    # the examples, background default, and fan syntax in those exact bytes. Benchmark variants edit
    # named anchors and fail if an anchor moved, so a supposed variant cannot silently become the
    # baseline. Historical captures retain the row identifiers under which they were measured; they
    # are never rewritten to match a later prompt.
    module Rows
      # A step reads only what it is handed: `results:` is the whole read of a model or a script, a
      # model naming nothing reads its prompt alone, what no step reads comes back to the caller,
      # and neither word removes a wait of written order.
      READ_CLAUSE = "A STEP READS ONLY WHAT YOU HAND IT. `results: [a, b]` on a model or\n" \
                    "script hands that step the results of a and b, in that order — a model\n" \
                    "ahead of its prompt, a script as results[0], results[1] — and waits for\n" \
                    "them. `results:` takes any list of handles: `results: runs` for an\n" \
                    "array you built with .map. A model step without `results:` reads its\n" \
                    "prompt alone, whatever ran before it: nothing reaches a step by\n" \
                    "position, and no step sees another step's conversation. Every result\n" \
                    "no step reads comes back to you.\n" \
                    "`after: [earlierHandle, ...]` on any leaf adds a wait without a result.\n" \
                    "Neither `results:` nor `after:` removes the waits of written order.\n".freeze

      VERB_TABLE_HEAD = [
        "  g.tool({ name, input, after? })      // run one of your tools; after adds waits only",
        "  g.model({ prompt, tools?, after?, results? }) // a fresh agent with an EMPTY context: it sees its",
        "                                       //   prompt and the results you hand it, not this conversation;",
        "                                       //   it has your tools except task and compose",
        "  g.ask({ prompt, after? })             // ask a person; their answer is this step's output",
        "  g.wait({ task, agent_loop?, timeout_ms?, after? }) // observe an existing task by its launch receipt",
        "  g.script({ script, params?, after?, results? }) // a later pure JavaScript stage over the results you hand it",
      ].freeze
      private_constant :VERB_TABLE_HEAD

      # The verb table: no step carries a WHEN word; the fan's join word is `until`, spelled as a
      # count of successes — a word no boolean fits, so the "never false" clause of 1b went with the
      # rename.
      VERB_TABLE = [
        *VERB_TABLE_HEAD,
        "  g.parallel([ ...steps ], { until? }) // run these at once; until: how many successes end the",
        "                                       //   fan — \"all\" (default), \"any\", or a number",
      ].map { |line| "#{line}\n" }.join.freeze

      # An independent chain is a parallel member; a follower still waits for the whole fan.
      ORDER_ANCHOR = "To keep a chain from waiting for unrelated work, put the whole chain\n" \
                     "beside that work: g.parallel([[read, review], other]). A step after".freeze
      FAN_SENTENCE = 'an "all" group still waits for every member.'.freeze

      # The example block opens on the two handles its fan groups and closes on the report that
      # names the summary and the person's answer; the per-item pipeline follows it, before the
      # peers example.
      EXAMPLE_BLOCK_START = "  const tests = g.tool({ name: \"bash\", input: { command: \"bin/rails test\" } });\n".freeze
      EXAMPLE_BLOCK_END = "  g.model({ prompt: \"Write the final report, applying the reviewer's answer.\", " \
                          "results: [summary, answer] });\n".freeze
      NESTED_EXAMPLE = "  g.parallel([\"test/models\", \"test/controllers\"].map((dir) => {\n" \
                       "    const run = g.tool({ name: \"bash\", input: { command: \"bin/rails test \" + dir } });\n" \
                       "    return [run, g.model({ prompt: \"Name each failing test under \" + dir + \" as file:line.\", " \
                       "results: [run] })];\n" \
                       "  }));  // two pairs at once; each model step is handed only its own run".freeze

      # Producers and readers as peers of one group, each reader naming what it reads, and the
      # combiner after the group naming the two readings — the example models copy.
      PEERS_EXAMPLE = "  const a = g.tool({name: \"bash\", input: {command: \"git diff\"}});\n" \
                      "  const b = g.tool({name: \"bash\", input: {command: \"bin/rails test\"}});\n" \
                      "  const c = g.model({prompt: \"Review the patch.\", results: [a]});\n" \
                      "  const d = g.model({prompt: \"Assess the patch and test results.\", results: [a, b]});\n" \
                      "  g.parallel([a, b, c, d]); // C needs only A; D needs A and B, never C\n" \
                      "  g.model({prompt: \"Combine the reviews.\", results: [c, d]});\n".freeze

      # The call runs in the background by default; `wait: true` opts into waiting.
      DEFAULT_SENTENCE = "The kernel runs the graph and delivers the\n" \
                         "results to you later, as a message that is not from the person.".freeze
      WAIT_PARAGRAPH = "By default this call runs in the background: your next round does not\n" \
                       "wait for it, and its results reach you as a message not from the person —\n" \
                       "never poll for them, and never write as though you already know them.\n" \
                       "`wait: true` on the call makes the next round wait for the results.".freeze
      LIFETIME_PARAGRAPH = "`lifetime: \"turn\"` requires this reply to consume and synthesize the\n" \
                           "results before becoming final, even when the call does not wait.\n" \
                           "`lifetime: \"conversation\"` delivers unwaited results in a new turn after\n" \
                           "this reply, even if they finish sooner.\n" \
                           "Omit to inherit the calling work's lifetime; ordinary replies default\n" \
                           "to conversation lifetime. Dependencies and explicit stops still apply.".freeze
      WAKE_PARAGRAPH = "`wake: \"passive\"` records a completion after the final answer as\n" \
                       "conversation history without starting another reply. Omit to inherit\n" \
                       "the calling work's wake mode; ordinary replies default to \"auto\".\n" \
                       "`wait: true` and turn-lifetime joining still consume results in this\n" \
                       "reply. Standalone loops have no later turn and await all results.".freeze

      STAGE_PARAMS_SENTENCE = "in scope. Its `params` is the stage's own `params` option: nothing from\n" \
                              "the outer script, neither its variables nor its `params`, reaches it.\n".freeze

      # A stage reads only the results it declares, like every step.
      STAGE_READS_SENTENCE = "The stage sees ONLY explicitly declared results, not prior history.\n".freeze

      # A model step naming a race is handed each result the race selected, and a tool result's
      # envelope names its call — the tool and the start of its input — so a model tells the members
      # apart with no step of its own authoring a label. It says so of tool results only (a model
      # result carries the start of its prompt instead, and a stage's slot for a race is `RACE_SLOT`)
      # and of races only.
      RACE_READER_LINES = "`results: [race]` reads what the race selected. A model step reading it\n" \
                          "sees each selected tool result named by its call, so a race's members\n" \
                          "need no extra step to name them.\n".freeze

      # A race is one step a later step may name, and naming it reads what it selected; naming a
      # member instead would wait on a loser the race stops. The example is the spelling itself.
      RACE_REFERENCE = "Only preceding leaf handles and races from this script are valid,\n" \
                       "never an \"all\" group, a string key, a future step, or a task from an\n" \
                       "earlier call. A race stops the members it did not select, so a later\n" \
                       "step names the race, never one of its members:\n" \
                       "`const race = g.parallel([a, b, c], { until: \"any\" })`, then\n" \
                       "#{RACE_READER_LINES}".freeze

      # A g.wait observes work from an earlier call by its receipt, and a later step reads what it
      # observed only by naming it.
      WAIT_READ_CLAUSE = "To observe work from an earlier call, g.wait names the actual task\n" \
                         "and optional source agent_loop from its launch receipt. Its target\n" \
                         "is not a handle and is never prefixed by this call; use after and\n" \
                         "results for steps in this script. A later step reads what a g.wait\n" \
                         "observed only through results: [w].\n".freeze

      # A stage's slot for a race is envelope-shaped: the first envelope the race selected, or the
      # race's own failure when it failed, and beside it every envelope it hands a reader — a failed
      # race's partial winners, then its failure.
      RACE_SLOT = "For a race, `results[i]` is the first envelope it selected, or the\n" \
                  "race's failure when it failed; `results[i].selected` lists what it\n" \
                  "hands you, first finisher first, a failure last.\n".freeze

      # A delivered tool result names the call that produced it (the envelope's `<call>` line), said
      # right after the read sentences, so a model need not author its own label to tell those
      # results apart.
      CALL_SENTENCE = "Every tool result, read by a model step or delivered to you, names the\n" \
                      "call that produced it: the tool and the start of its input.\n".freeze

      # The top level is no result boundary: what no step reads comes back, so the work ends on one
      # step that reads the rest, and a computed list keeps its fan and reducer inside one stage.
      BOUNDARY_PARAGRAPH = "The compose call's top-level `script` is NOT a result boundary: what no\n" \
                           "step reads comes back to you, so end the work with one step that reads\n" \
                           "the rest. When the list itself is computed from results, put the\n" \
                           "listing, fan and reducer inside ONE g.script task, as the example does;\n" \
                           "only its final leaf crosses that boundary.\n".freeze

      # Anchors that pin each intended clause and example in the shipped compose text.
      LANDED = {
        "a step reads only what it is handed; after adds a wait only" => READ_CLAUSE,
        "the per-item pipeline example, after the example block" => "#{EXAMPLE_BLOCK_END}\n#{NESTED_EXAMPLE}\n",
        "the initial builder delivers future results" => DEFAULT_SENTENCE,
        "the wait paragraph: the background default, and immediate wait opt-in" => WAIT_PARAGRAPH,
        "the lifetime paragraph: final delivery is independent of immediate wait" => LIFETIME_PARAGRAPH,
        "the wake paragraph: passive completion becomes history without a model reply" => WAKE_PARAGRAPH,
        "a follower waits for the whole all-group" => FAN_SENTENCE,
        "leaf references and script stages beside the until fan" => VERB_TABLE,
        "a stage's params is its own option; nothing from the outer script reaches it" => STAGE_PARAMS_SENTENCE,
        "a later step names a race, never one of its members, and a model reading it sees each tool result's call" =>
          RACE_REFERENCE,
        "a stage's slot for a race is its first selected envelope or its failure, with what it hands a reader" => RACE_SLOT,
        "a tool result names the call that produced it" => CALL_SENTENCE,
        "a g.wait's observation is read only by naming it" => WAIT_READ_CLAUSE,
        "peers of one group, each reader naming what it reads" => PEERS_EXAMPLE,
        "the top level is no result boundary: what no step reads comes back" => BOUNDARY_PARAGRAPH,
        "a stage reads only the results it declares" => STAGE_READS_SENTENCE,
      }.freeze

      # The id the registry's text carries on this tree: when a variant becomes the registry's text,
      # this takes the variant's id. `shipped` is no id: `find` answers it with this tree's shipped
      # row whatever its id, so a definition that must run on any tree reads the text that tree ships.
      SHIPPED_ID = "R-LADDER".freeze
      SHIPPED = "shipped".freeze

      # A re-cut is one entry: its id and its edit over the shipped bytes, written with `recut` so a
      # moved anchor raises; `E2E_BENCH_ROWS` picks rows by id. A variant is added per bench. When a
      # variant becomes the registry's text, the shipped row takes its id and the other variants are
      # deleted, so a record's row always names the bytes it was measured on.
      VARIANTS = {}.freeze

      # A ROW IS A TEMPLATE: `description` is the plain render the pins read and the model gets
      # under the `nexus` style; `template` keeps the registry's tool-name macros so another style
      # re-spells `{{task}}` in compose's text as its own name (`Styles`). A row cut from plain text
      # alone has no macro left to re-spell.
      Row = Data.define(:id, :description, :template) do
        def initialize(id:, description:, template: description) = super

        # The compose entry as the wire sees it under a set's spellings —
        # none for the plain bytes.
        def definition(spellings = {})
          Nexus::Compose::DEFINITION.merge(
            "function" => Nexus::Compose::DEFINITION.fetch("function")
              .merge("description" => Nexus::ToolRegistry.render_text(template, spellings))
          )
        end

        def slug = id.downcase.tr("+", "-")
      end

      def self.shipped = Nexus::ToolRegistry.wire_schema_for(Nexus::Compose::TOOL_NAME).fetch("description")

      def self.shipped_template = Nexus::ToolRegistry.entry("nexus.graph.compose").template

      # One named edit: `from` must stand in `base` — the shipped text
      # moved otherwise, and the row must be re-cut by hand, not skipped.
      def self.recut(base, from, to)
        raise ArgumentError, "the anchor moved; re-cut the row: #{from.lines.first.strip.inspect}" unless base.include?(from)

        base.sub(from, to)
      end

      # A re-cut edits the template and the plain text alike. Its anchors
      # must match both forms; tool-name macros remain in the template.
      def self.all
        [Row.new(id: SHIPPED_ID, description: shipped, template: shipped_template),
         *VARIANTS.map { |id, edit| Row.new(id: id, description: edit.call(shipped), template: edit.call(shipped_template)) }]
      end

      def self.ids = all.map(&:id)

      # `||`, not `or`: in an endless def `or raise` binds outside the
      # definition and never raises, so an unknown id came back nil.
      def self.find(id) = id == SHIPPED ? all.first : all.find { |row| row.id == id } || raise(ArgumentError, "no row #{id}")
    end
  end
end
