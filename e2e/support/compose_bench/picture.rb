require_relative "shape"
require_relative "waits"

module E2E
  module ComposeBench
    # AN OBJECTIVE'S EXPECTED GRAPH, and whether a lowered script IS it. The picture names nodes by
    # role (`a`, `na`, `merge`), never by the keys a model chose, so the comparison is a
    # correspondence under which the waits and the reads are EQUAL. A picture checks the dataflow
    # its objective exists for, never one spelling of it: each label takes a node of its own kind,
    # or of a kind the picture admits in its place (`"model|script"` — a value stage reading the
    # sources a model step would read computes what that step computes), and a label with reads is
    # compared on the reads of the node it took, whatever its kind. What a tool read depends on
    # the step the label pictures. Where the step DECIDES on its reads (O2's edit), a tool reads
    # what the stages above it decided on — one written blind decided nothing. Where the step
    # COMPUTES over them (`computes:`, O7's normalisers), a tool reads what it waits on as well: its
    # input was fixed when the script was written, so what it computes over is what the steps it
    # waits on left behind — `sh bin/normalise a` reads the file its fetch wrote.
    #
    # Waits compare as closure: both sides are reduced to the edges nothing else implies (`Waits`),
    # so a `results:` or `after:` restating a wait the chain already makes is no defect. Over-sync
    # is still the defect measured, because any wait that is not implied changes the closure: the
    # silent buckets read it as containment — a wait one side implies and the other does not —
    # never as an edge count, which a restated wait inflates and a serialized chain can match.
    #
    # Three kinds of node beyond the labels are admitted. A TRANSPARENT stage — a value stage of the
    # plan that ran that something consumes (`Executed::Plan#transparent`) and that no label takes
    # — is contracted: what waited into it waits into what waited on it, and a read of it is a read
    # of what it read, so a tag stage at a race arm's tail hands the race its probe, while the same
    # stage reading its own fetch stands where O7 has a normaliser. The other two are deleted with
    # their waits before the comparison. A VALUE — a `script` stage no label takes, that nothing
    # waits on, and that computes one: it places no step and the kernel does not fail it — is the
    # plan's answer: the compose text recommends ending on one readable leaf, and a leaf nothing
    # waits on changes no wait among the others. Past a TAIL (`tail: "fix"`, `tail: "e"`) the graph
    # may extend the chain that ends there: each extra step waits on the tail, waits on and reads
    # nothing the labels took but the tail and what the tail waits on, and nothing the labels took
    # waits on it — so a re-lint or a report after O4's fix stands, and a step reading the suite
    # does not; a verify grep after O2's edit stands, and a blind step before it does not. Past a
    # tail whose step decides (O2's edit), a tool that edits (`Shape::EDITS`) and read nothing is no
    # extension: it was written before anything answered, the guessed edit the label exists to
    # refuse, wherever it stands. A picture with a tail sets no value apart: an extra there is read
    # as one.
    class Picture
      # A label and the kinds of node that may take it: its own first, then any the picture admits.
      Expected = Data.define(:label, :kinds, :detached) do
        def kind = kinds.first

        # A node of the label's own kind, or of an admitted kind that computes a value: a stage that
        # places steps computes nothing itself (the steps it places do), and one the kernel fails
        # computes nothing at all.
        def admits?(node, valueless) = node.detached == detached &&
          (node.kind == kind || (kinds.include?(node.kind) && !valueless.include?(node.key)))
      end
      # Pairs of matched steps where one side waits and the other does not, and where both do.
      Sync = Data.define(:over, :under, :agree) do
        def total = over + under
        # Closer: fewer disagreements, then more agreeing waits.
        def rank = [total, -agree]
      end

      attr_reader :nodes, :edges, :reads, :tail, :computes

      # nodes: { label => "tool" | "model" | "ask" | "join" | "model!" (background) | "tool!" }, a kind
      # admitted beside the label's own after a bar (`"model|script"`); edges: [[from, to],...];
      # reads: { model label => [labels] }; tail: the label whose chain extra steps may extend;
      # computes: the labels admitting a tool whose step computes over its reads. A "join" is a race
      # join, the only join the lowering places. A model is never admitted in another kind's place:
      # the correspondences pair each kind with its own first, so two labels admitting each other's
      # kind could miss the one pairing that is exact.
      def initialize(nodes:, edges:, reads:, tail: nil, computes: [])
        @nodes = nodes.map do |label, spec|
          kinds = spec.delete_suffix("!").split("|")
          raise ArgumentError, "#{label}: a model is never admitted in another kind's place" if kinds.drop(1).include?("model")

          Expected.new(label: label, kinds: kinds, detached: spec.end_with?("!"))
        end
        unless computes.all? { |label| @nodes.any? { |node| node.label == label && node.kinds.drop(1).include?("tool") } }
          raise ArgumentError, "computes: #{computes.inspect} names a label that admits no tool"
        end

        @edges = edges.map { |from, to| [from, to] }
        @reads = reads
        @tail = tail
        @computes = computes
        @waits = Waits.of(@edges, joins: @nodes.select { |node| node.kind == "join" }.map(&:label))
      end

      def read_count = @reads.values.sum(&:length)
      def count(kind) = @nodes.count { |node| node.kind == kind }
      def reduced_edges = @waits.reduced

      # The verdict, with the silent buckets beside it when it is not exact. `placers` are the
      # stages the reading knows place steps (`Inlined#placers`), `refused` the ones it knows the
      # kernel fails (`Inlined#refused`): neither computes a value, so neither stands in for a model
      # nor drops out as the plan's answer, and a refused stage extends no chain — a placer past
      # O4's fix places the re-lint, which does. `transparent` are the value stages of the plan
      # that ran that something consumes (`Executed::Plan#transparent`). `stage_fed` are the model
      # steps of the plan that ran whose stage handed them values in their prompts where the graph
      # cannot tell which (`Executed.stage_fed`): one reading nothing is `stage_fed`, never blind.
      def score(graph, placers: [], refused: [], transparent: [], stage_fed: [])
        valueless = placers | refused
        values = values(graph, valueless)
        verdict = ->(&check) { exact(graph, values, valueless, refused, transparent, &check) }
        both = verdict.call { |core, mapping| edges_equal?(waits_of(core), mapping) && reads_equal?(core, mapping) }
        if both
          { "exact_edges" => true, "exact_reads" => true, "silent" => [] }
        else
          exact_edges = !verdict.call { |core, mapping| edges_equal?(waits_of(core), mapping) }.nil?
          {
            "exact_edges" => exact_edges,
            "exact_reads" => !verdict.call { |core, mapping| reads_equal?(core, mapping) }.nil?,
            "silent" => silent_buckets(graph, values, valueless, transparent, exact_edges, stage_fed),
          }
        end
      end

      private

        # The graph's values: the `script` stages that compute one and that nothing waits on.
        def values(graph, valueless)
          if @tail.nil?
            waited = graph.edges.map(&:first)
            graph.nodes.select { |node| node.kind == "script" && !valueless.include?(node.key) && !waited.include?(node.key) }.map(&:key)
          else
            []
          end
        end

        # The correspondence under which the graph is the picture: every label takes a node it
        # admits, the transparent stages no label took are contracted, every node left over is
        # admitted, and the graph without those passes the check. Contraction keeps every wait
        # among the nodes it leaves, so the closure is the whole graph's.
        def exact(graph, values, valueless, refused, transparent)
          return nil unless countable?(graph, values | transparent)

          closure = waits_of(graph).closure
          contracted = Hash.new { |cache, gone| cache[gone] = graph.contract(gone) }
          correspondences(graph).find do |mapping|
            extras = graph.keys - mapping.values
            core = contracted[extras & transparent]
            rest = extras - transparent
            admitted?(graph, mapping, valueless) && extras_admitted?(core, mapping, rest, values, refused, closure) &&
              yield(core.without(rest), mapping)
          end
        end

        # Enough nodes for every label, and no more beyond the stages set apart unless a tail admits them.
        def countable?(graph, set_apart)
          graph.nodes.length >= @nodes.length && (!@tail.nil? || graph.nodes.length - set_apart.length <= @nodes.length)
        end

        def admitted?(graph, mapping, valueless)
          mapping.size == @nodes.size &&
            @nodes.all? { |expected| expected.admits?(graph.node(mapping.fetch(expected.label)), valueless) }
        end

        def extras_admitted?(graph, mapping, extras, values, refused, closure)
          if @tail.nil?
            (extras - values).empty?
          else
            (extras & refused).empty? && extends?(graph, mapping, extras, closure)
          end
        end

        # Each extra waits on the tail and touches nothing the labels took but the chain the tail
        # ends, and nothing the labels took waits on an extra — so no wait among them runs through
        # one, and deleting the extras leaves their waits as they were. A guessed edit is never one.
        def extends?(graph, mapping, extras, closure)
          tip = mapping.fetch(@tail)
          core = mapping.values
          chain = [tip, *core.select { |key| closure.include?([key, tip]) }]
          extras.none? { |extra| guessed?(graph.node(extra)) } &&
            extras.all? { |extra| closure.include?([tip, extra]) && (touched(graph, extra, core, closure) - chain).empty? } &&
            core.none? { |key| extras.any? { |extra| closure.include?([extra, key]) } }
        end

        # An edit no step decided, past a tail whose step decides: a tool that edits and read nothing.
        def guessed?(node) = decides?(@tail) && node.kind == "tool" && node.edits? && node.reads.empty?

        # A label whose step decides on its reads: it admits a tool in a model's place, and the tool
        # does not compute over them.
        def decides?(label) = expected(label).kinds.drop(1).include?("tool") && !@computes.include?(label)

        # What of the labels' nodes an extra waits on or reads.
        def touched(graph, extra, core, closure)
          core.select { |key| closure.include?([key, extra]) } | (graph.node(extra).reads & core)
        end

        # Every way to pair the picture's labels with the graph's keys: as many kind- and
        # detachment-preserving pairs as each kind allows, then the steps left over on both sides
        # paired across kinds, so a stage standing where a model was pictured still holds that
        # model's place in the waits. A join pairs only with a join. Where the kinds match, these
        # are exactly the bijections; the graphs are a handful of nodes, so the search is small.
        # A label that admits a second kind also sits its own kind's pairing out, so the leftover pass
        # can offer it the node of the admitted kind even where its own kind has enough nodes —
        # a value stage that IS the merge beside a stray model; the plain pairing comes first. Sitting
        # out reaches many pairings twice, and each is offered once.
        def correspondences(graph)
          admitting = @nodes.select { |node| node.kinds.length > 1 }.map(&:label)
          Enumerator.new do |yielder|
            offered = Set.new
            (0..admitting.length).flat_map { |size| admitting.combination(size).to_a }.each do |withheld|
              groups = @nodes.reject { |node| withheld.include?(node.label) }.group_by { |node| [node.kind, node.detached] }.map do |group, expected|
                injections(expected.map(&:label), graph.nodes.select { |node| [node.kind, node.detached] == group }.map(&:key))
              end
              [{}].product(*groups) do |parts|
                paired = parts.reduce({}, :merge)
                spare = graph.nodes.reject { |node| node.kind == "join" || paired.value?(node.key) }.map(&:key)
                left = @nodes.reject { |node| node.kind == "join" || paired.key?(node.label) }.map(&:label)
                injections(left, spare).each do |rest|
                  mapping = paired.merge(rest)
                  yielder << mapping if offered.add?(mapping)
                end
              end
            end
          end
        end

        # Every pairing of as many labels with distinct keys as the smaller side allows.
        def injections(labels, keys)
          if labels.length <= keys.length
            keys.permutation(labels.length).map { |chosen| labels.zip(chosen).to_h }
          else
            labels.permutation(keys.length).map { |chosen| chosen.zip(keys).to_h }
          end
        end

        def waits_of(graph) = Waits.of(graph.edges, joins: graph.nodes.select { |node| node.kind == "join" }.map(&:key))

        # Directed: `a→na` and `na→a` are different pictures.
        def edges_equal?(theirs, mapping)
          theirs.reduced.sort == @waits.reduced.map { |from, to| [mapping.fetch(from), mapping.fetch(to)] }.sort
        end

        # Reads compare as sets: a `parallel`'s members contribute in the order written, and which
        # member the model wrote first is not a property of the shape. A label with reads is
        # compared on the reads of the node it took, whatever its kind; a foreground model that no
        # such label took is compared too, and never matches.
        def reads_equal?(graph, mapping)
          @reads.all? { |label, sources| read_matches?(graph, mapping, label, sources) } &&
            (graph.reads.keys - @reads.keys.map { |label| mapping.fetch(label) }).empty?
        end

        # Whether the node a label took reads what the label pictures, under a mapping that may
        # leave either unpaired (the closest correspondence of a graph that is not the picture).
        def read_matches?(graph, mapping, label, sources)
          key = mapping[label]
          expected = sources.map { |source| mapping[source] }
          !key.nil? && !expected.include?(nil) && reads_at(graph, label, key).sort == expected.sort
        end

        # What the node a label took read: its own reads, and, for a tool where the label's step
        # computes, what it waits on besides — every direct wait, one the chain already implies
        # included, since what it waits on is what it can read. So a wait such a tool should not
        # make is read twice, as the wait (`over_sync`) and as what it computes over
        # (`over_read_named`: the wait is the script's own).
        def reads_at(graph, label, key)
          node = graph.node(key)
          computing?(label, node) ? node.reads | graph.edges.filter_map { |from, to| from if to == key } : node.reads
        end

        def computing?(label, node) = node.kind == "tool" && @computes.include?(label)

        # WHAT WENT WRONG SILENTLY on a script the builder accepted: the
        # dataflow verdict's buckets plus the two this grammar can miss (a
        # race spelled as an `all` fan; a tip the picture leaves free — the
        # suite nothing should wait on — waited on by a later step: O4's
        # `suite; lint; fix`, under the detached default where "later" is
        # spelled by the fan, never by a step; a graph with no edge waits on
        # nothing, so an empty plan never reads it). The buckets read the graph
        # the verdict read: a value drops out and a transparent stage is
        # contracted, unless the closest correspondence stands it where a label
        # admits it, and then it is read as that step.
        # Over- and under-sync are read under the closest correspondence; a
        # reads-only mismatch whose waits are exact is `reads_mismatch`, and
        # `wrong_task_read` is what is left. Past a tail, the steps the tail
        # admits are deleted first, so a re-lint after O4's fix is never read as
        # the suite. `edit_as_tool` counts every tool, except where the picture
        # admits a tool in a model's place: where the label's step decides
        # (O2's edit), a tool a stage decided on what it read stands for a
        # model, and where it computes (O7's normalisers), a tool the closest
        # correspondence stands there does; only the models the other tools
        # replace are guessed edits. `edit_as_stage` names a stage standing
        # where the label's step decides, with nothing past it that could have
        # decided in its place, when no other bucket applies. The over-reads
        # and `blind_model` weigh the reads `weighed_reads` names — a foreground
        # model's, a stage standing where a label admits it, a tool standing
        # where the label's step computes — so a computing tool that waits on
        # nothing is blind too: a stand-in reads wrong in the bucket a model
        # would. An over-read is split by where it came from:
        # `over_read_positional`, any read that did not come through a step's
        # `results:` (`Shape::Node#positional` — none on a script's lowering, so
        # on the plan that ran it is the kernel's fault, never the model's), and
        # `over_read_named`, `results:` naming more than the picture reads. A
        # model a stage fed values the graph cannot attribute
        # (`Executed.stage_fed`) reading nothing is `stage_fed`, never blind,
        # and so is a credit (`Shape::Node#credited`) that reads more than the
        # picture: the model's author named none of it.
        def silent_buckets(graph, values, valueless, transparent, exact_edges, stage_fed = [])
          kept = held(graph, values | transparent)
          read = graph.contract(transparent - kept).without(values - kept - transparent)
          past = @tail.nil? ? [] : extensions(read).map { |key| read.node(key) }
          read = read.without(past.map(&:key))
          mapping, sync = closest(read, waits_of(read))
          weighed = weighed_reads(read, mapping, valueless)
          tools = read.nodes.select { |node| node.kind == "tool" }
          computing = mapping.filter_map { |label, key| key if computing?(label, read.node(key)) }
          deciding = @nodes.any? { |node| decides?(node.label) }
          standing = tools.count { |node| computing.include?(node.key) || (deciding && node.reads.any?) }
          buckets = []
          buckets << "edit_as_tool" if count("model") > read.count("model") + standing && tools.length - standing > count("tool")
          buckets << "missing_join" if count("join") > read.count("join")
          buckets << "suite_waited_on" if read.edges.any? && free_tips(@edges, @nodes.map(&:label)) > free_tips(read.edges, read.keys)
          buckets << "extra_steps" if read.nodes.length > @nodes.length
          buckets << "missing_steps" if read.nodes.length < @nodes.length
          buckets << "over_sync" if sync.over.positive?
          buckets << "under_sync" if sync.under.positive?
          positional = weighed.keys.flat_map { |key| read.node(key).positional }
          credited = weighed.sum { |key, reads| (reads & read.node(key).credited).length }
          named = weighed.sum { |key, reads| (reads - read.node(key).positional - read.node(key).credited).length }
          blind = weighed.select { |_, reads| reads.empty? }.keys
          buckets << "over_read_positional" if positional.any?
          buckets << "over_read_named" if named > read_count
          buckets << "blind_model" if (blind - stage_fed).any? && @reads.values.none?(&:empty?)
          buckets << "stage_fed" if blind.intersect?(stage_fed) || (named <= read_count && named + credited > read_count)
          buckets << "edit_as_stage" if buckets.empty? && stage_where_a_step_decides?(read, mapping, past)
          buckets << (exact_edges ? "reads_mismatch" : "wrong_task_read") if buckets.empty?
          buckets
        end

        # A stage standing where the label's step decides (O2's edit), with no model step and no editing
        # tool among the steps the tail admitted past it: the picture admits no stage there — on the plan
        # that ran it placed no edit, and the static reading cannot see what a stage places, so a refused
        # stage or a known placer there reads the same — and nothing after it could have decided the edit
        # on what it read. A stage a later model reads is that model's filter, and stays in the fallback:
        # the model may have decided. Named before the fallback, never over a sharper bucket.
        def stage_where_a_step_decides?(graph, mapping, past)
          past.none? { |node| node.kind == "model" || (node.kind == "tool" && node.edits?) } &&
            mapping.any? { |label, key| decides?(label) && graph.node(key).kind == "script" }
        end

        # The values and transparent stages the closest correspondence stands where a label admits
        # them (neither places a step, so no placer is among them).
        def held(graph, set_apart)
          if set_apart.empty?
            []
          else
            mapping, = closest(graph, waits_of(graph))
            set_apart.select { |key| mapping.any? { |label, taken| taken == key && expected(label).admits?(graph.node(key), []) } }
          end
        end

        # The reads the buckets weigh: every foreground model's, and a stage's standing where a label
        # admits it — as a model's would be — and a tool's standing where the label's step computes.
        # A decided tool's never: a tool at a label that decides is `edit_as_tool`'s.
        def weighed_reads(graph, mapping, valueless)
          stand_ins = mapping.filter_map do |label, key|
            node = graph.node(key)
            [key, reads_at(graph, label, key)] if (node.kind == "script" || computing?(label, node)) && expected(label).admits?(node, valueless)
          end
          graph.reads.merge(stand_ins.to_h)
        end

        # The steps a TAIL admits past its label, on a graph that is not exact: under the closest
        # correspondence, each step below the tail, never a guessed edit, whose waits and reads
        # outside what lies below the tail are the tail's chain, and that nothing else waits on —
        # deleted only while every label still has a step.
        def extensions(graph)
          mapping, = closest(graph, waits_of(graph))
          tip = mapping && mapping[@tail]
          return [] if tip.nil?

          closure = waits_of(graph).closure
          chain = [tip, *@nodes.filter_map { |node| mapping[node.label] if @waits.closure.include?([node.label, @tail]) }]
          below = graph.keys.select { |key| closure.include?([tip, key]) }
          outside = graph.keys - below
          found = below.select do |key|
            !guessed?(graph.node(key)) &&
              ((outside.select { |other| closure.include?([other, key]) } | (graph.node(key).reads & outside)) - chain).empty?
          end
          loop do
            waited = found.select { |key| (graph.keys - found).any? { |other| closure.include?([key, other]) } }
            break if waited.empty?

            found -= waited
          end
          graph.nodes.length - found.length >= @nodes.length ? found : []
        end

        def expected(label) = @nodes.find { |node| node.label == label }

        # The correspondence under which the graph's waits are closest to the picture's, and how
        # close they are; a tie goes to the one whose labels read what they picture, never to the
        # order the steps were written in.
        def closest(graph, theirs)
          best = nil
          correspondences(graph).each do |mapping|
            found = [mapping, sync(mapping, theirs), @reads.count { |label, sources| !read_matches?(graph, mapping, label, sources) }]
            best = found if best.nil? || (rank(found) <=> rank(best)).negative?
            break if best[1].total.zero? && best[2].zero?
          end
          best&.first(2)
        end

        def rank(found) = [*found[1].rank, found[2]]

        # Over: the graph makes one matched step wait on another and the picture does not. Under:
        # the picture does and the graph does not.
        def sync(mapping, theirs)
          pairs = mapping.to_a.permutation(2).map do |(label, key), (other, other_key)|
            [@waits.closure.include?([label, other]), theirs.closure.include?([key, other_key])]
          end
          Sync.new(over: pairs.count { |pictured, waited| waited && !pictured },
            under: pairs.count { |pictured, waited| pictured && !waited },
            agree: pairs.count { |pictured, waited| pictured && waited })
        end

        # Nodes no edge leaves: the picture's receipts.
        def free_tips(edges, keys)
          waited = edges.map(&:first)
          keys.count { |key| !waited.include?(key) }
        end
    end
  end
end
