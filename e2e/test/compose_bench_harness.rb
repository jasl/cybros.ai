$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "mini_racer"
require "minitest/autorun"
require "tmpdir"
require "support/compose_bench"
require_relative "../../nexus/lib/nexus/compose/grammar"

# THE BENCH'S OWN SCORERS, before any money is spent (memory `verify-the-stated-property`): the
# lowering here must wait by written order and read by the kernel's own read rule, and lower every
# script to the graph the kernel places for it; every objective's picture must be EXACTLY what a
# canonical script for it lowers to through the shipped evaluator, a near-miss must NOT pass and
# must land in the named silent bucket, the shipped row must be the registry's bytes carrying each
# landed edit at its place, a re-cut's moved anchor must be loud, and the readout must write.
#
# The suites that pin those, one concern each, share this module: the bench's names, the canonical
# scripts, and the three ways a test reaches the shipped evaluator.
module ComposeBenchHarness
  Shape = E2E::ComposeBench::Shape
  Objectives = E2E::ComposeBench::Objectives
  Rows = E2E::ComposeBench::Rows
  Tools = E2E::ComposeBench::Tools
  Styles = E2E::ComposeBench::Styles

  # A canonical script per objective, each step handed what it reads by name — a step reads
  # only what its `results:` hand it (`Nexus::Compose::Reads`), so a combiner names what it
  # combines. The pictures suite pins that each scores exact on both columns; the rows and probe
  # suites reuse them as scripts known to be right.
  CANONICAL = {
    "O1" => <<~JS,
      const reviews = [
        g.model({ prompt: "Read patch.diff and review it for security problems." }),
        g.model({ prompt: "Read patch.diff and review it for performance problems." }),
        g.model({ prompt: "Read patch.diff and review it for style." }),
      ];
      g.parallel(reviews);
      g.model({ prompt: "Weigh the three reviews and give one verdict.", results: reviews });
    JS
    "O2" => <<~JS,
      const user = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/user.rb" } });
      const account = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/account.rb" } });
      const team = g.tool({ name: "grep", input: { pattern: "def full_name", path: "app/models/team.rb" } });
      g.parallel([user, account, team]);
      g.model({ prompt: "Rename full_name to display_name in the file whose grep matched.", results: [user, account, team] });
    JS
    "O3" => <<~JS,
      const race = g.parallel([
        g.tool({ name: "probe_host", input: { host: "alpha" } }),
        g.tool({ name: "probe_host", input: { host: "bravo" } }),
        g.tool({ name: "probe_host", input: { host: "charlie" } }),
      ], { until: "any" });
      g.model({ prompt: "Say which host responded first.", results: [race] });
    JS
    "O4" => <<~JS,
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      g.parallel([
        g.tool({ name: "bash", input: { command: "bin/rails test" } }),
        [lint, g.model({ prompt: "Fix every offence the lint output names.", results: [lint] })],
      ]);
    JS
    "O7" => <<~JS,
      const normalised = ["a", "b", "c"].map((source) => {
        const fetch = g.tool({ name: "bash", input: { command: "curl -s https://" + source + ".example/feed" } });
        return [fetch, g.model({ prompt: "Normalise source " + source + ".", results: [fetch] })];
      });
      g.parallel(normalised);
      g.model({ prompt: "Merge the three normalised sets.", results: normalised.map((pair) => pair[1]) });
    JS
    "O7b" => <<~JS,
      const tests = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const testSummary = g.model({ prompt: "Summarise the test failures.", results: [tests] });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const types = g.tool({ name: "bash", input: { command: "bin/srb tc" } });
      const checks = g.parallel([lint, types]);
      const qualitySummary = g.model({ prompt: "Summarise code quality from lint and types.", results: [lint, types] });
      g.parallel([[tests, testSummary], [checks, qualitySummary]]);
      g.model({ prompt: "Write the report from the two summaries.", results: [testSummary, qualitySummary] });
    JS
    # Isolated as the prompt asks: peers in one group, each naming its inputs in `results:`, so a
    # review reads its own head and the dump and nothing else written before the group.
    "T5" => <<~JS,
      const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
      const seed = g.tool({ name: "bash", input: { command: "bin/rails db:seed" } });
      const dump = g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" }, after: [migrate, seed] });
      const migrateReview = g.model({ prompt: "Review the migrate output together with the schema dump.", results: [migrate, dump] });
      const seedReview = g.model({ prompt: "Review the seed output together with the schema dump.", results: [seed, dump] });
      const merge = g.model({ prompt: "Merge the two reviews into one.", results: [migrateReview, seedReview] });
      g.parallel([migrate, seed, dump, migrateReview, seedReview, merge]);
    JS
  }.freeze

  # Alternative authored spellings put the merge after its parallel group. Producer and reader
  # peers retain explicit inputs regardless of where the final combiner is declared.
  SECOND_CANONICAL = {
    "O7b" => <<~JS,
      const tests = g.tool({ name: "bash", input: { command: "bin/rails test" } });
      const lint = g.tool({ name: "bash", input: { command: "bin/rubocop app" } });
      const types = g.tool({ name: "bash", input: { command: "bin/srb tc" } });
      const failures = g.model({ prompt: "Summarise failures.", results: [tests] });
      const quality = g.model({ prompt: "Summarise quality.", results: [lint, types] });
      g.parallel([tests, lint, types, failures, quality]);
      g.model({ prompt: "Combine summaries.", results: [failures, quality] });
    JS
    "T5" => <<~JS,
      const migrate = g.tool({ name: "bash", input: { command: "bin/rails db:migrate" } });
      const seed = g.tool({ name: "bash", input: { command: "bin/rails db:seed" } });
      const dump = g.tool({ name: "bash", input: { command: "bin/rails db:schema:dump" }, after: [migrate, seed] });
      const migrateReview = g.model({ prompt: "Review the migrate output together with the schema dump.", results: [migrate, dump] });
      const seedReview = g.model({ prompt: "Review the seed output together with the schema dump.", results: [seed, dump] });
      g.parallel([migrate, seed, dump, migrateReview, seedReview]);
      g.model({ prompt: "Merge the two reviews into one.", results: [migrateReview, seedReview] });
    JS
  }.freeze

  # ONE CALL'S ANSWER as the probe reads it off a client: the calls, the text, and the facts
  # `ManualClient.facts` reads (the finish, its detail, the spend) — absent unless a test names
  # them.
  Answer = Data.define(:tool_calls, :output_text, :finish_reason, :usage, :finish_detail) do
    def initialize(tool_calls:, output_text:, finish_reason: nil, usage: nil, finish_detail: nil) = super
  end

  DEFAULT_ROUTE = E2E::ProviderLanes::Route.new(ref: "openrouter/acme/test-model",
    lane: E2E::ProviderLanes.lane("openrouter"), model: "acme/test-model")

  # A client whose calls are answered in turn by the lambdas it was given, each handed the
  # request, so a sample's whole path runs before the first paid call does.
  # A synthetic model on the broker protocol: a scripted answer needs no
  # wire, but the probe reads the profile to decide the kernel's cache markers (none on this wire).
  class ScriptedClient
    PROFILE = E2E::ManualClient.for(DEFAULT_ROUTE,
      env: { "OPENROUTER_API_KEY" => "scripted-placeholder" }).execution_profile

    def initialize(*answers) = @answers = answers
    def responses = self
    def execution_profile = PROFILE
    def create(**request) = @answers.shift.call(request)
  end

  private

    def compose_call(script, params: nil)
      arguments = JSON.generate({ "script" => script, "params" => params }.compact)
      Answer.new([{ "id" => "c1", "name" => "compose", "arguments" => arguments }], "")
    end

    # The synthetic broker model unless a test names a protocol or adaptation case.
    def route(ref = nil) = ref ? E2E::ProviderLanes.route(ref) : DEFAULT_ROUTE

    def evaluate(script, params: {})
      Nexus::Compose::Evaluator.call(script: script, params: params, tool_names: Tools::NAMES)
    end

    def lower(script, params: {})
      built = evaluate(script, params: params)
      flunk "#{built.refusal}: #{built.detail}" unless built.built?
      Shape.lower(built.steps)
    end

    def refusal(script)
      built = evaluate(script)
      flunk "expected a refusal for #{script}" if built.built?
      built.detail
    end
end
