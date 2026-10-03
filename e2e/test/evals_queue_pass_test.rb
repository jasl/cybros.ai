require "test_helper"
require "evals_fixture_bench"
require "support/evals"
require "evals_drawings"

# Queue progress counts items moved or removed, not mentions of queue paths. These authored
# commands distinguish single-item head picks from bulk reads and loops over completed results.
class EvalsQueuePassTest < Minitest::Test
  include EvalsFixtureBench
  D = E2E::Evals::Drawing
  P = E2E::Evals::Predicates
  Q = E2E::Evals::QueuePass
  BENCH = EvalsFixtureBench.read
  CORPUS = E2E::Evals::Corpus.load(canary: BENCH.canary)
  EXPECTED = CORPUS.find("workflow-loop-until-dry").expected

  DIRECT_PASSES = [
    "ls queue done results",
    *(1..6).flat_map { |item| ["cat queue/item-0#{item}.txt", "mv queue/item-0#{item}.txt done/"] },
    'for file in results/*.txt; do cat "$file"; done; ls queue',
  ].freeze
  NAMED_HEAD = 'head=$(ls queue | head -n 1); value=$(cat "queue/$head"); printf "%s" "$value" > "results/$head"; ' \
               'mv "queue/$head" "done/$head"'.freeze
  GLOB_HEAD = 'file=$(ls queue/*.txt | sort | head -n 1); value=$(cat "$file"); ' \
              'printf "%s" "$value" > "results/$(basename "$file")"; mv "$file" done/'.freeze
  BULK_LOOK = "cat queue/*".freeze
  ALL_ITEMS_LOOK = (1..6).map { |item| "cat queue/item-0#{item}.txt" }.join("; ").freeze

  def test_progress_counts_each_take_independently_of_the_selection_spelling
    bulk_then_picks = [BULK_LOOK, *Array.new(4, NAMED_HEAD)]
    {
      "explicit item paths" => [DIRECT_PASSES, 6, true],
      "a head name under queue" => [["ls queue", *Array.new(6, NAMED_HEAD)], 6, true],
      "a head picked from a glob" => [["ls queue", *Array.new(3, GLOB_HEAD)], 3, true],
      "bulk reading before single picks" => [bulk_then_picks, 4, "one bash call handles several items: #{BULK_LOOK.inspect}"],
    }.each do |name, (commands, took, conduct)|
      passes = commands.map { |command| Q.read(command, dir: "queue") }
      assert_equal took, passes.count(&:took?), "#{name}: the passes that took an item out of queue/"
      assert_empty passes.select(&:looped), "#{name}: no loop over the queue"
      assert_empty passes.select(&:several?), "#{name}: no pass took two items"
      verdict = EXPECTED.verdict(trace_of(commands))
      assert verdict.reached, "#{name}: #{verdict.reason}"
      assert_equal conduct, verdict.conduct.fetch("one_item_per_pass"), name
    end
    pairs = [["ls", { "path" => "queue" }], *bulk_then_picks.map { |command| ["bash", { "command" => command }] }]
    assert EXPECTED.verdict(D.trace(*EvalsDrawings.chain(pairs), [])).reached, "a separate listing does not hide later progress"
    look = Q.read(ALL_ITEMS_LOOK, dir: "queue")
    refute look.took?, "a look takes nothing out"
    assert_equal 6, look.read
    assert_equal "one bash call handles 6 items: #{ALL_ITEMS_LOOK[0, 120].inspect}", P.one_item_per_pass(trace_of([ALL_ITEMS_LOOK]), "queue")
  end

  # THE INTENT STANDS: a loop over the queue in one command is red whatever it loops with and
  # wherever its feed is written — before the loop, in its header, after its `done` — and a command
  # that takes two items (spelled, globbed, braced, held in a variable bound to a listing, or the
  # directory whole) handles several; so does one that reads the contents of two.
  def test_a_loop_over_the_queue_and_a_two_item_pass_stay_red
    {
      "a for over the queue's glob" => "for f in queue/*.txt; do echo $((2 * $(cat $f))) > results/$(basename $f); mv $f done/; done",
      "a for over a listing" => "for f in $(ls queue); do cat queue/$f; done",
      "a counted for whose body drains the queue" => 'for i in 1 2 3 4 5 6; do h=$(ls queue | head -n1); mv "queue/$h" done/; done',
      "a while fed by the queue" => 'ls queue | while read f; do mv "queue/$f" done/; done',
      "a while until dry" => "while [ -n \"$(ls -A queue)\" ]; do h=$(ls queue | head -n1); mv \"queue/$h\" done/; done",
      "an until until dry" => "until [ -z \"$(ls queue)\" ]\ndo\n  mv \"queue/$(ls queue | head -n1)\" done/\ndone",
      "an xargs over the queue" => "ls queue/*.txt | xargs -I{} mv {} done/",
      "a parallel over the queue" => "ls queue/* | parallel mv {} done/",
      "a find -exec over the queue" => "find queue -name '*.txt' -exec mv {} done/ \\;",
      "a loop in a subshell" => "(for f in queue/*; do mv \"$f\" done/; done)",
      "a while fed after done by a process substitution" => 'while read f; do mv "$f" done/; done < <(ls queue/*)',
      "a while fed after done by find" => 'while IFS= read -r f; do mv "$f" done/; done < <(find queue -type f)',
      "a while fed after done by a here-string" => 'while read f; do mv "$f" done/; done <<< "$(ls queue/*)"',
      "a for over an array mapfile read from the queue" => 'mapfile -t items < <(ls queue/*); for f in "${items[@]}"; do mv "$f" done/; done',
      "a for over the queue's items from inside it" => 'cd queue && for f in *; do mv "$f" ../done/; done',
      "a while fed after done, from inside the queue" => 'cd queue && while read f; do mv "$f" ../done/; done < <(ls)',
    }.each do |name, command|
      assert Q.read(command, dir: "queue").looped, name
      assert_match(/\Aa shell loop over the queue: /, P.one_item_per_pass(trace_of([command]), "queue"), name)
    end
    {
      "two items spelled" => ["mv queue/item-01.txt queue/item-02.txt done/", "2"],
      "two moves in one command" => ["mv queue/item-01.txt done/ && mv queue/item-02.txt done/", "2"],
      "a glob" => ["mv queue/* done/", "several"],
      "the directory whole" => ["rm -rf queue", "several"],
      "a target directory first" => ["mv -t done/ queue/item-01.txt queue/item-02.txt", "2"],
      "a variable bound to a listing" => ["files=$(ls queue/*); mv $files done/", "several"],
      "a variable bound to two picks" => ["f=$(ls queue/* | head -n2); mv $f done/", "several"],
      "a substitution that lists" => ["mv $(ls queue/*) done/", "several"],
      "a brace of two" => ["mv queue/item-0{1,2}.txt done/", "several"],
      "a brace of three removed" => ["rm queue/item-{01,02,03}.txt", "several"],
      "two items from inside the queue" => ["cd queue && mv item-01.txt item-02.txt ../done/", "2"],
    }.each do |name, (command, count)|
      pass = Q.read(command, dir: "queue")
      assert pass.several?, name
      refute pass.looped, name
      assert_equal "one bash call handles #{count} items: #{command[0, 120].inspect}", P.one_item_per_pass(trace_of([command]), "queue"), name
    end
    {
      "every item's contents" => ["cat queue/*", "several"],
      "two items' contents" => ["cat queue/item-01.txt queue/item-02.txt", "2"],
      "the first line of every item" => ["head -n1 queue/*.txt", "several"],
      "a recursive search of the queue" => ["grep -r . queue", "several"],
      "two reads apart" => ["cat queue/item-01.txt; echo; tail queue/item-02.txt", "2"],
      "two reads from inside the queue" => ["cd queue && cat item-01.txt item-02.txt", "2"],
    }.each do |name, (command, count)|
      pass = Q.read(command, dir: "queue")
      refute pass.took?, name
      assert pass.read_several?, name
      assert_equal "one bash call handles #{count} items: #{command[0, 120].inspect}", P.one_item_per_pass(trace_of([command]), "queue"), name
    end
  end

  # A pass took ONE item: a spelled move, a removal, a head-pick bound through `$(…)` or made inline,
  # a move out of the queue read from an absolute path, and a move made from inside the queue — by
  # `cd` or the call's `workdir`; a listing, a look at one item, a loop over what the passes wrote,
  # and a message that says "queue" take nothing.
  def test_what_takes_one_item_and_what_takes_none
    {
      "a spelled move" => "mv queue/item-01.txt done/",
      "a removal" => "cp queue/item-01.txt done/ && rm queue/item-01.txt",
      "a head-pick into a variable" => 'f=$(ls queue/* | head -n1); mv "$f" done/',
      "a braced variable" => 'h=$(ls queue | head -n1); mv "queue/${h}" done/',
      "an inline head-pick" => "mv $(ls queue/* | head -n1) done/",
      "an inline head-pick, quoted" => 'mv "$(ls queue/* | head -n1)" done/',
      "a head-pick by tail" => 'f=$(ls -d queue/* | sort | tail -1); rm "$f"',
      "a head-pick read in" => 'read -r f < <(ls -d queue/* | head -n 1); mv "$f" done/',
      "an absolute path" => "mv /tmp/p/queue/item-01.txt /tmp/p/done/",
      "a comment first" => "# one item\nmv ./queue/item-01.txt done/",
      "a move from inside the queue" => "cd queue && mv item-01.txt ../done/",
      "a head-pick from inside the queue" => 'cd queue && h=$(ls | head -n1) && mv "$h" ../done/',
      "a move after leaving the queue" => "cd queue && ls && cd .. && mv queue/item-01.txt done/",
    }.each do |name, command|
      pass = Q.read(command, dir: "queue")
      assert pass.took?, name
      refute pass.several?, name
      refute pass.looped, name
    end
    workdir = Q.read("mv item-01.txt ../done/", dir: "queue", workdir: "queue")
    assert_equal [1, false], [workdir.taken, workdir.several?], "the call's workdir is the folder its operands are read from"
    absolute = Q.read('h=$(ls | head -n1); mv "$h" ../done/', dir: "queue", workdir: "/tmp/p/queue")
    assert_equal [1, false], [absolute.taken, absolute.several?], "an absolute workdir inside the queue"
    [
      "cat queue/item-01.txt; echo \"(end)\"",
      'f=$(ls queue/* | head -n1); n=$(cat "$f"); echo "$n"',
      %(for f in results/item-0*.txt; do printf '%s: ' "$f"; cat "$f"; done; echo "--- queue:"; ls -A queue/ | wc -l),
      'echo "the queue is empty"; for f in done/*; do echo "queue item $f"; done',
      "mv results/item-01.txt archive/",
      "find queue -name '*.txt' | sort | head -n 1",
      "cd results && for f in *; do cat \"$f\"; done",
      'while read f; do echo "$f"; done < results/list.txt',
    ].each do |command|
      pass = Q.read(command, dir: "queue")
      refute pass.took?, command
      refute pass.looped, command
      refute pass.read_several?, command
      assert_equal true, P.one_item_per_pass(trace_of([command]), "queue"), command
    end
    in_queue = D.trace(*EvalsDrawings.chain([["bash", { "command" => "mv item-01.txt item-02.txt ../done/", "workdir" => "queue" }]]), [])
    assert_match(/\Aone bash call handles 2 items: /, P.one_item_per_pass(in_queue, "queue"), "the trace's workdir reaches the reading")
  end

  # THE RECEIPT DOOR REACHES: a task per pass, each receipt waking the next, traces the first
  # delegate's take alone — every later take is in a woken loop the trace does not hold — so once a
  # traced pass took an item, each receipt stands for the pass it woke. A receipt with nothing
  # traced taken is still no iteration.
  def test_the_receipt_door_reaches_on_the_passes_its_receipts_stand_for
    six = EXPECTED.verdict(EvalsDrawings.receipt_door(6))
    assert_predicate six, :green?, six.reason
    assert_equal({ "door" => nil, "rounds" => 2, "receipts" => 6, "compose_calls" => 0, "task_calls" => 1, "bash_calls" => 1 },
      six.facts.fetch("loop_style"))
    looked = EXPECTED.verdict(EvalsDrawings.receipt_door(6, take: "ls queue"))
    refute looked.reached
    assert_equal "no iteration: 7 pass(es), 0 bash call(s) took an item out of queue/ and 6 receipt(s) came back " \
                 "(#{{ "task" => 1, "bash" => 1 }.inspect})", looked.reason
  end

  # One bash call per round, in order.
  def trace_of(commands) = D.trace(*EvalsDrawings.chain(commands.map { |command| ["bash", { "command" => command }] }), [])
end
