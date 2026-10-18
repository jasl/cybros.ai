require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

class EvalsCoverageTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  Coverage = E2E::Evals::Coverage
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  CONFIGS = %w[config/app.yml config/db.yml config/cache.yml].freeze
  SOURCES = %w[lib/alpha.rb lib/bravo.rb lib/charlie.rb].freeze
  CONTROL_REPLY = { "reply" => "config/db.yml and config/cache.yml set debug to true" }.freeze
  ROOT = "/home/u/projects/task-grep-three-control.nexus.1".freeze

  # The first round of every v10 run of the three-grep control, as the kernel recorded it.
  V10_FIRST_ROUNDS = [
    [["read", { "path" => "config/app.yml" }], ["read", { "path" => "config/db.yml" }], ["read", { "path" => "config/cache.yml" }]],
    [["bash", { "command" => "ls -la; echo \"---\"; ls -la config 2>/dev/null" }], ["grep", { "path" => "config", "pattern" => "debug" }]],
    [["grep", { "path" => "config", "pattern" => "debug" }]],
    [["grep", { "path" => "config", "pattern" => "debug", "ignoreCase" => true }]],
    [["grep", { "glob" => "{app,db,cache}.yml", "path" => "config", "pattern" => "debug" }]],
    [["grep", { "glob" => "*.yml", "path" => "config", "pattern" => "debug" }]],
    [["grep", { "glob" => "*.yml", "path" => "config", "context" => 2, "pattern" => "debug" }]],
    [["grep", { "path" => "config/app.yml", "context" => 1, "pattern" => "debug" }],
     ["grep", { "path" => "config/db.yml", "context" => 1, "pattern" => "debug" }],
     ["grep", { "path" => "config/cache.yml", "context" => 1, "pattern" => "debug" }]],
  ].freeze

  def test_a_call_covers_a_file_by_its_path_its_folder_or_a_glob_over_it
    {
      "one grep of the folder" => [["grep", { "pattern" => "debug", "path" => "config" }]],
      "a grep of the folder under a basename glob" => [["grep", { "pattern" => "debug", "glob" => "*.yml", "path" => "config" }]],
      "a grep under a brace glob" => [["grep", { "pattern" => "debug", "glob" => "{app,db,cache}.yml", "path" => "config" }]],
      "a grep from the root under a path glob" => [["grep", { "pattern" => "debug", "glob" => "**/config/*.yml" }]],
      "a grep of the folder under a path glob" => [["grep", { "pattern" => "debug", "glob" => "**/config/*.yml", "path" => "config" }]],
      "a grep excluding another glob" => [["grep", { "pattern" => "debug", "path" => "config", "glob" => "!*.json" }]],
      "three reads by absolute path" => CONFIGS.map { |file| ["read", { "path" => "/home/u/project/#{file}" }] },
      "a grep over a shell glob" => [["bash", { "command" => "grep -n debug config/*.yml" }]],
      "a recursive grep of the root" => [["bash", { "command" => "grep -rn debug ." }]],
      "one cat of the three" => [["bash", { "command" => "cat config/app.yml config/db.yml config/cache.yml" }]],
      "a grep in the folder by workdir" => [["bash", { "command" => "grep -n debug app.yml db.yml cache.yml", "workdir" => "config" }]],
      "a shell glob by workdir" => [["bash", { "command" => "grep -n debug *.yml", "workdir" => "config" }]],
      "a cat after cd" => [["bash", { "command" => "cd config && cat app.yml db.yml cache.yml" }]],
      "an absolute cd into the folder" => [["bash", { "command" => "cd /home/u/project/config; cat *.yml" }]],
      "an rg listing the files it matched" => [["bash", { "command" => "rg -l debug config" }]],
      "an rg under a glob flag from the root" => [["bash", { "command" => "rg -g '*.yml' debug" }]],
      "an rg under a path glob from the root" => [["bash", { "command" => "rg -g 'config/*.yml' debug" }]],
      "a grep with its pattern by -e" => [["bash", { "command" => "grep -rn -e debug config" }]],
      "three delegations, one per file" => CONFIGS.map { |file| ["delegate_task", { "prompt" => "Does #{file} set debug: true?" }] },
      "a delegation naming the folder as a path" => [["delegate_task", { "prompt" => "grep -rn debug config/" }]],
    }.each do |name, calls|
      assert_equal CONFIGS, Coverage.covered(drawn(calls), CONFIGS), name
    end
  end

  def test_a_listing_a_search_elsewhere_or_a_missing_file_covers_nothing_more
    {
      "two reads" => [%w[config/app.yml config/db.yml], CONFIGS.first(2).map { |file| ["read", { "path" => file }] }],
      "a grep under a glob that matches none" => [[], [["grep", { "pattern" => "debug", "glob" => "*.json", "path" => "config" }]]],
      "a listing" => [[], [["bash", { "command" => "ls -la config" }]]],
      "a find" => [[], [["find", { "pattern" => "*.yml", "path" => "config" }]]],
      "a non-recursive grep of the folder" => [[], [["bash", { "command" => "grep debug config" }]]],
      "a shell glob from another folder" => [[], [["bash", { "command" => "cat *.yml" }]]],
      "a recursive grep from another workdir" => [[], [["bash", { "command" => "grep -rn debug .", "workdir" => "lib" }]]],
      "a recursive grep after cd elsewhere" => [[], [["bash", { "command" => "cd lib && grep -rn debug ." }]]],
      "a grep under a path glob rg anchors to its own cwd" => [[], [["grep", { "pattern" => "debug", "glob" => "config/*.yml" }]]],
      "an rg listing" => [[], [["bash", { "command" => "rg --files config" }]]],
      "an rg listing of the root under a glob" => [[], [["bash", { "command" => "rg --files -g '*.yml'" }]]],
      "a grep excluding one file" => [%w[config/db.yml config/cache.yml], [["grep", { "pattern" => "debug", "path" => "config", "glob" => "!app.yml" }]]],
      "an rg whose glob flag matches none" => [[], [["bash", { "command" => "rg -g '*.json' debug config" }]]],
      "a grep whose include matches none" => [[], [["bash", { "command" => "grep -r --include='*.json' debug config" }]]],
      "a grep excluding one file by flag" => [%w[config/db.yml config/cache.yml], [["bash", { "command" => "grep -r --exclude app.yml debug config" }]]],
      "delegations about other files" => [[], EvalsDrawings::FIVE_TASKS.map { |row| ["delegate_task", row["tool_input"]] }],
      "a delegation whose prose says config" => [["config/app.yml"], [["delegate_task", { "prompt" => "Summarize what the app config in config/app.yml says about debug." }]]],
      "a delegation about another file that says config" => [[], [["delegate_task", { "prompt" => "Check the logging config in docs/logging.md" }]]],
    }.each do |name, (expected, calls)|
      assert_equal expected, Coverage.covered(drawn(calls), CONFIGS), name
    end
  end

  def test_every_v10_first_round_of_the_control_covered_the_three_files
    V10_FIRST_ROUNDS.each do |calls|
      assert_equal CONFIGS, Coverage.covered(drawn(calls), CONFIGS), calls.inspect
    end
  end

  # THE CONTROL REACHES BY WHAT THE RUN COVERED: over every round, so a first round spent listing
  # the folder still reaches and its later over-reach is scored; the first round's fan and cover
  # ride as facts.
  def test_the_three_grep_control_reaches_by_what_the_whole_run_covered
    expected = CORPUS.find("task-grep-three-control").expected
    V10_FIRST_ROUNDS.each do |calls|
      verdict = expected.verdict(drawn(calls, facts: CONTROL_REPLY))
      assert_predicate verdict, :green?, "#{calls.inspect}: #{verdict.reason}"
    end
    later = expected.verdict(drawn([["bash", { "command" => "ls config" }]], later: CONFIGS.map { |file| ["delegate_task", { "prompt" => "grep debug in #{file}" }] }))
    assert verdict_reached_and_over_reached?(later), later.reason
    assert_equal({ "covered" => CONFIGS, "covered_in_first_round" => [], "calls_in_first_round" => 1 },
      later.facts.slice("covered", "covered_in_first_round", "calls_in_first_round"))
    delegated = expected.verdict(drawn(CONFIGS.map { |file| ["delegate_task", { "prompt" => "Does #{file} set debug: true?" }] }))
    assert verdict_reached_and_over_reached?(delegated), delegated.reason
    short = expected.verdict(drawn(CONFIGS.first(2).map { |file| ["read", { "path" => file }] }))
    refute short.reached
    assert_match(/covered 2 of the 3 files \(config\/cache\.yml unread\)/, short.reason)
    elsewhere = expected.verdict(D.trace(EvalsDrawings::FIVE_GRAPH, EvalsDrawings::FIVE_TASKS, []))
    assert_match(/covered 0 of the 3 files/, elsewhere.reason)
  end

  # task-two-calls' success reads the same coverage: a grep of `lib` read the three files.
  def test_the_two_calls_success_reads_the_same_coverage
    expected = CORPUS.find("task-two-calls").expected
    reply = { "reply" => "Only lib/charlie.rb defines `run`." }
    folder = expected.verdict(drawn([["grep", { "pattern" => "def self", "path" => "lib" }], ["bash", { "command" => "ls lib" }]], facts: reply))
    assert_predicate folder, :green?, folder.reason
    listed = expected.verdict(drawn([["bash", { "command" => "ls lib" }], ["read", { "path" => "lib/charlie.rb" }]], facts: reply))
    assert_equal "lib/alpha.rb, lib/bravo.rb never covered by a call", listed.reason
    rg_listed = expected.verdict(drawn([["bash", { "command" => "rg --files lib" }], ["read", { "path" => "lib/charlie.rb" }]], facts: reply))
    assert_equal "lib/alpha.rb, lib/bravo.rb never covered by a call", rg_listed.reason
    by_workdir = expected.verdict(drawn([["bash", { "command" => "cat alpha.rb bravo.rb charlie.rb", "workdir" => "lib" }],
                                         ["bash", { "command" => "ls", "workdir" => "lib" }]], facts: reply))
    assert_predicate by_workdir, :green?, by_workdir.reason
    anchored = expected.verdict(drawn([["grep", { "pattern" => "def self", "glob" => "lib/*.rb" }], ["bash", { "command" => "ls lib" }]], facts: reply))
    assert_equal "lib/alpha.rb, lib/bravo.rb, lib/charlie.rb never covered by a call", anchored.reason
    delegated = expected.verdict(drawn(SOURCES.map { |file| ["delegate_task", { "prompt" => "Read #{file}" }] }, facts: reply))
    assert_match(/over-reach/, delegated.reason)
  end

  # THE RUN'S ROOT SPELLED ABSOLUTELY holds every file: the lane stamps the root it pointed the
  # tools at, so a grep of that absolute folder reads the three files, and another folder does not.
  def test_the_run_s_absolute_root_holds_every_file
    rooted = { "root" => ROOT }
    {
      "a grep of the absolute project root" => [["grep", { "pattern" => "debug", "path" => ROOT }]],
      "a grep of the absolute root under a glob" => [["grep", { "pattern" => "debug", "path" => "#{ROOT}/", "glob" => "*.yml" }]],
      "a recursive grep of the absolute root" => [["bash", { "command" => "grep -rn debug #{ROOT}" }]],
      "a recursive grep by an absolute workdir" => [["bash", { "command" => "grep -rn debug .", "workdir" => ROOT }]],
    }.each do |name, calls|
      assert_equal CONFIGS, Coverage.covered(drawn(calls, facts: rooted), CONFIGS), name
    end
    assert_equal [], Coverage.covered(drawn([["grep", { "pattern" => "debug", "path" => "/home/u/projects/other" }]], facts: rooted), CONFIGS)
    control = CORPUS.find("task-grep-three-control").expected.verdict(drawn([["grep", { "pattern" => "debug", "path" => ROOT }]],
      facts: CONTROL_REPLY.merge(rooted)))
    assert_predicate control, :green?, control.reason
    two_calls = CORPUS.find("task-two-calls").expected.verdict(drawn([["grep", { "pattern" => "def self", "path" => ROOT }], ["bash", { "command" => "ls lib" }]],
      facts: { "reply" => "Only lib/charlie.rb defines `run`.", "root" => ROOT }))
    assert_predicate two_calls, :green?, two_calls.reason
  end

  # Only a call that completed read anything: a read or a grep that answered an error read nothing
  # (rg refused the search, the file was not there), and a canceled call never ran; bash's error is
  # its exit status, which a reader that ran still returns, so it keeps its cover.
  def test_a_call_that_read_nothing_covers_nothing
    errored = { "is_error" => true, "resolved" => true }
    {
      "a grep rg refused" => D.tool("r1t0", "grep", after: ["r1"], input: { "path" => "config", "pattern" => "debug: (true" }).merge("result" => errored),
      "a read of a missing path" => D.tool("r1t0", "read", after: ["r1"], input: { "path" => "/workspace/config/app.yml" }).merge("result" => errored),
      "a canceled cat" => D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "cat config/*.yml" }, status: "canceled"),
    }.each do |name, row|
      assert_equal [], Coverage.covered(D.trace(D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task")], [%w[r1 r1t0]]), [row], []), CONFIGS), name
    end
    missed = D.tool("r1t0", "bash", after: ["r1"], input: { "command" => "grep -n 'debug: false' config/*.yml" }).merge("result" => errored)
    assert_equal CONFIGS, Coverage.covered(D.trace(D.graph([D.n("r1", "model_task"), D.n("r1t0", "tool_task")], [%w[r1 r1t0]]), [missed], []), CONFIGS)
  end

  # THE PLAIN FOR-LOOP READS ITS WORDS (the v11 bench's task-grep-three-control kimi-k3 #2, "the
  # calls covered 0 of the 3 files" over a loop that cat'ed all three): `for VAR in WORD...; do …
  # "$VAR" …; done` reads as its body once per word. A word list with an expansion in it stays as
  # written, and so does a loop variable no reader names.
  KIMI_K3_LOOP = 'for f in config/app.yml config/db.yml config/cache.yml; do echo "=== $f ==="; cat "$f" 2>/dev/null || echo "(missing)"; done'

  def test_a_plain_for_loop_covers_what_its_body_reads_for_every_word
    assert_equal CONFIGS, Coverage.covered(drawn([["bash", { "command" => KIMI_K3_LOOP }]]), CONFIGS)
    {
      "one read per word, braced and bare" => [CONFIGS, "for f in app db cache; do grep -n debug config/${f}.yml; head $f; done"],
      "a word list over a glob" => [CONFIGS, "for f in config/*.yml\ndo\n  cat $f\ndone"],
      "two words of three" => [CONFIGS.first(2), "for f in config/app.yml config/db.yml; do cat \"$f\"; done"],
      "an echo of each word" => [[], "for f in config/app.yml config/db.yml config/cache.yml; do echo \"$f\"; done"],
      "a word list from a command" => [[], "for f in $(ls config); do cat \"config/$f\"; done"],
      "another variable" => [[], "for f in config/app.yml; do cat \"$file\"; done"],
      "a `done` quoted in the body" => [CONFIGS, 'for f in config/app.yml config/db.yml config/cache.yml; do echo "--- $f (done below)"; cat "$f"; done'],
      "two loops, the second plain" => [CONFIGS.last(2), "for d in a b; do for g in x; do echo $g; done; done; for f in config/db.yml config/cache.yml; do cat $f; done"],
    }.each do |name, (expected, command)|
      assert_equal expected, Coverage.covered(drawn([["bash", { "command" => command }]]), CONFIGS), name
    end
    control = CORPUS.find("task-grep-three-control").expected.verdict(drawn([["bash", { "command" => KIMI_K3_LOOP }]], facts: CONTROL_REPLY))
    assert_predicate control, :green?, control.reason
    assert_equal CONFIGS, control.facts.fetch("covered_in_first_round")
  end

  def verdict_reached_and_over_reached?(verdict) = verdict.reached && verdict.succeeded == false && verdict.reason.match?(/over-reach/)

  # `calls` fanned by r1, `later` by r2.
  def drawn(calls, later: [], facts: {})
    first = calls.each_with_index.map { |(name, input), index| D.tool("r1t#{index}", name, after: ["r1"], input: input) }
    second = later.each_with_index.map { |(name, input), index| D.tool("r2t#{index}", name, after: ["r2"], input: input) }
    keys = first + second
    graph = D.graph([D.n("r1", "model_task"), *keys.map { |row| D.n(row["key"], "tool_task") }, D.n("r2", "model_task"),
                     D.n("r3", "model_task", deliverable: true)],
      [*first.flat_map { |row| [["r1", row["key"]], [row["key"], "r2"]] }, *second.flat_map { |row| [["r2", row["key"]], [row["key"], "r3"]] }])
    D.trace(graph, keys, [], facts: facts)
  end
end
