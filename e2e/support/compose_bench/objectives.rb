require_relative "picture"

module E2E
  module ComposeBench
    # THE OBJECTIVES. Each prompt states the TASK — never the script, never a verb of the grammar —
    # and, except the control, says to build it as one compose script now. Each carries its expected
    # picture derived from the prompt's waits and each step's inputs; the harness test pins
    # every picture against a canonical script through the shipped evaluator, so "exact" is the
    # stated property and not a correlate.
    module Objectives
      Objective = Data.define(:id, :slug, :gate, :text, :picture, :note) do
        def control? = picture.nil?
      end

      BUILD = "Build this as one compose script, right now; do not read or run anything first."

      ALL = [
        # O1 — the ceiling objective, restated as a task.
        Objective.new(
          id: "O1", slug: "review-angles", gate: true,
          text: "Review patch.diff from three angles at the same time — security, performance and " \
                "style — three fresh agents, each opening patch.diff itself. Then one more agent " \
                "reads all three reviews and gives a single verdict. #{BUILD}",
          picture: Picture.new(
            nodes: { "m1" => "model", "m2" => "model", "m3" => "model", "v" => "model" },
            edges: [%w[m1 v], %w[m2 v], %w[m3 v]],
            reads: { "m1" => [], "m2" => [], "m3" => [], "v" => %w[m1 m2 m3] }
          ),
          note: "three model members in one parallel, one model after it reading all three"
        ),
        # O2 — scores the "cannot know yet" sentence: the edit is decided on what the greps said — a
        # model step reading them, or a tool a stage placed after reading them (on the plan that
        # ran, the tool reads what its stages read); a tool written before the greps answered reads
        # nothing and is `edit_as_tool`. Steps after the edit that wait on it and touch only its
        # chain — a verify grep, a report, a closing value stage — are the same dataflow (`tail`),
        # and so the first step decided on the greps takes the edit's label: a `read` of the
        # defining file a stage placed before the edit is that step, the edit and its verify after
        # it extending it. A tool between the greps and the edit that a stage did not decide reads
        # nothing, takes no label and is an extra step; an `edit` or `write` that read nothing extends
        # no chain either — past a step that read the greps, and may only have reported them, it is
        # still the guessed edit.
        Objective.new(
          id: "O2", slug: "grep-then-edit", gate: true,
          text: "Find which of app/models/user.rb, app/models/account.rb and app/models/team.rb " \
                "defines the method `full_name` (grep each one), then rename that method to " \
                "`display_name` in the one file that defines it. #{BUILD}",
          picture: Picture.new(
            nodes: { "g1" => "tool", "g2" => "tool", "g3" => "tool", "e" => "model|tool" },
            edges: [%w[g1 e], %w[g2 e], %w[g3 e]],
            reads: { "e" => %w[g1 g2 g3] },
            tail: "e"
          ),
          note: "three greps at once, then the edit decided on them: a model step, or a tool a stage placed after reading them; " \
                "steps after the edit may verify it"
        ),
        # O3 — decides the `until` line. The winner may be a model step after the race or a value
        # stage naming the race itself (`results: [race]`), which waits on the join alone and reads
        # the probes the race selected from; a stage or a model naming the probes one by one waits
        # on each, a loser included, and reads `over_sync`.
        Objective.new(
          id: "O3", slug: "race", gate: false,
          text: "Probe the hosts alpha, bravo and charlie. The first one that responds is the one " \
                "we will use and I do not care about the rest — stop waiting on them. Then tell me " \
                "which host won. #{BUILD}",
          picture: Picture.new(
            nodes: { "p1" => "tool", "p2" => "tool", "p3" => "tool", "j" => "join", "w" => "model|script" },
            edges: [%w[p1 j], %w[p2 j], %w[p3 j], %w[j w]],
            reads: { "w" => %w[p1 p2 p3] }
          ),
          note: "a race (until: any or 1) over three probes, then a step after the join that names the winner: " \
                "a model step, or a value stage reading results: [race]"
        ),
        # O4 — scores the fan under the detached default: nothing waits on the suite, so it sits
        # beside the [lint, fix] pair in one g.parallel — `g.parallel([g.tool(suite), [g.tool(lint),
        # g.model(fix)]])`; a sequential suite; lint; fix makes the fix wait on the suite, the
        # discrimination this objective exists for. Steps after the fix that extend the chain —
        # a re-lint, a report reading the fix and the lint — are the same dataflow (`tail`). Its
        # cross-turn half runs in live_task_matrix.
        Objective.new(
          id: "O4", slug: "background-suite", gate: true,
          text: "Run the whole test suite with `bin/rails test`; it takes twenty minutes and I do " \
                "not want anything to wait on it. Meanwhile run `bin/rubocop app` and fix every " \
                "offence it reports. #{BUILD}",
          picture: Picture.new(
            nodes: { "suite" => "tool", "lint" => "tool", "fix" => "model" },
            edges: [%w[lint fix]],
            reads: { "fix" => %w[lint] },
            tail: "fix"
          ),
          note: "the suite beside a [lint, fix] pair in one parallel: the fix reads the lint alone, nothing waits on the suite, " \
                "and steps after the fix may extend the chain"
        ),
        # O5 — the over-reach control: one call's worth of work composes nothing.
        Objective.new(
          id: "O5", slug: "single-read", gate: true,
          text: "What does app.yml set the log level to?",
          picture: nil,
          note: "must compose 0: one read_file call"
        ),
        # O7 — T4, the three-stage pairing (the nested-sequence clause's objective). Each normaliser is
        # its own step after its own fetch, reading that fetch alone: a model step, a value stage
        # naming the fetch in `results:`, or a tool — `sh bin/normalise a` computes over the file its
        # fetch wrote, so it reads what it waits on (`computes:`). A normalise folded into the fetch's
        # own command is no step, and the pairs read `missing_steps`. The merge reads the three
        # normalised sets it names, however the normalisers are spelled; one naming the raw fetches
        # too over-reads by its own names.
        Objective.new(
          id: "O7", slug: "three-stage-pairing", gate: false,
          text: "Fetch three sources at the same time with bash: `curl -s https://a.example/feed`, " \
                "`curl -s https://b.example/feed` and `curl -s https://c.example/feed`. Normalise " \
                "each source into our record format as soon as ITS OWN fetch is done — each " \
                "normaliser reads only its own source, and must not wait for the other fetches. " \
                "Finally merge the three normalised sets into one list. #{BUILD}",
          picture: Picture.new(
            nodes: { "a" => "tool", "b" => "tool", "c" => "tool",
                     "na" => "model|tool|script", "nb" => "model|tool|script", "nc" => "model|tool|script",
                     "merge" => "model|script" },
            edges: [%w[a na], %w[b nb], %w[c nc], %w[na merge], %w[nb merge], %w[nc merge]],
            reads: { "na" => %w[a], "nb" => %w[b], "nc" => %w[c], "merge" => %w[na nb nc] },
            computes: %w[na nb nc]
          ),
          note: "three [fetch, normalise] pairs at once — each normaliser a model step, a tool or a value stage after its own " \
                "fetch — then a merge reading the three normalisers: a model step or a value stage naming them"
        ),
        # O7b — the two-source fan-in inside a per-item chain (three bracket levels).
        Objective.new(
          id: "O7b", slug: "two-source-fan-in", gate: false,
          text: "Run `bin/rails test`, `bin/rubocop app` and `bin/srb tc` at the same time. One " \
                "agent summarises the test failures from the test output alone, as soon as the " \
                "tests finish. Another summarises code quality from the lint output and the " \
                "type-check output together, as soon as those two finish — it must not wait for " \
                "the tests. Then a final agent writes the report from the two summaries. #{BUILD}",
          picture: Picture.new(
            nodes: { "t" => "tool", "l" => "tool", "ty" => "tool",
                     "ts" => "model", "qs" => "model", "report" => "model" },
            edges: [%w[t ts], %w[l qs], %w[ty qs], %w[ts report], %w[qs report]],
            reads: { "ts" => %w[t], "qs" => %w[l ty], "report" => %w[ts qs] }
          ),
          note: "[test, summary] beside a member that fans lint and types into one summary; a report after"
        ),
        # The rendezvous joins migrate and seed before the dump, then both reviews before the merge,
        # each review reading its own head and the dump and never the other head, as the prompt
        # says. Isolation is `results:` — e.g. peers in one group, each naming its inputs — and a
        # review naming nothing reads its prompt alone, while a cat/review pair adds steps and hands
        # the review nothing. Record this objective's shape without treating it as a gate.
        Objective.new(
          id: "T5", slug: "rendezvous", gate: false,
          text: "Run `bin/rails db:migrate` and `bin/rails db:seed` at the same time, then " \
                "`bin/rails db:schema:dump` once both are done. Then two reviews at once: one " \
                "reads the migrate output together with the schema dump, the other reads the " \
                "seed output together with the schema dump — neither may see the other's " \
                "output. Finally merge the two reviews into one. #{BUILD}",
          picture: Picture.new(
            nodes: { "mig" => "tool", "seed" => "tool", "dump" => "tool",
                     "rm" => "model", "rs" => "model", "merge" => "model" },
            edges: [%w[mig dump], %w[seed dump], %w[dump rm], %w[dump rs], %w[rm merge], %w[rs merge]],
            reads: { "rm" => %w[mig dump], "rs" => %w[seed dump], "merge" => %w[rm rs] }
          ),
          note: "recorded: [migrate, seed] joined before the dump, two reviews after it each reading its own head and the dump, a merge of the two reviews"
        ),
      ].freeze

      def self.find(id) = ALL.find { |objective| objective.id == id } || raise(ArgumentError, "no objective #{id}")

      def self.ids = ALL.map(&:id)
    end
  end
end
