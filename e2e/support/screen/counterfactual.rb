require "json"
require_relative "../compose_bench/buckets"
require_relative "corpus"
require_relative "job"

module E2E
  module Screen
    # THE BUILDER COUNTERFACTUAL: every tracked first script of the corpora a definition names,
    # evaluated by EACH tree's own builder (`counterfactual_cli.rb`, run under that tree's bundle),
    # each under the names its group declared. A candidate that changes the builder may change what
    # a refusal SAYS and never what builds: the set of scripts that build must be the same in both
    # trees, or the launch stops. The refusals whose sentence a builder repair rewords — a nested
    # list, an "all" group, a value, a chain handed where a step is named — are listed old → new,
    # never refused on.
    #
    # In the with tree each script is also handed to the task bench's `Door.kind` as a compose call:
    # the door reader must answer a kind for every stored script, and one that raises stops the
    # launch, since a raise inside a draw's scoring is a harness fault that stops the watch.
    module Counterfactual
      CLI = "support/screen/counterfactual_cli.rb".freeze
      LISTED = %w[nested_list group_reference reference_value chain_reference].freeze

      module_function

      # Both trees' readings compared per corpus; the stamp's lines, or a refusal naming the step.
      def call(definition:, trees:, command: CAPTURE)
        ids = definition.stage0.fetch("counterfactual").fetch("corpus")
        without = run(trees.fetch("without"), ids, door: false, command: command)
        with = run(trees.fetch("with"), ids, door: true, command: command)
        ids.flat_map { |id| compared(id, rows_of(without, id), rows_of(with, id)) }
      end

      # One tree's rows: a JSON line per script, `corpus id built` and, when refused, its `bucket`;
      # with `door`, each script's `door_kind` or the `door_error` it raised.
      def run(root, ids, door:, command:)
        argv = ["bundle", "exec", "ruby", CLI, "--corpus", ids.join(","), *(door ? ["--door", "1"] : [])]
        out, ok, err = command.call(argv, chdir: File.join(root, "e2e"))
        raise Refused, "the counterfactual could not run in #{root}: #{err.to_s.lines.last(3).join.strip}" unless ok

        out.lines.select { |line| line.start_with?("{") }.map { |line| JSON.parse(line) }
      end

      # THE READING, inside one tree: every script of the corpus under its group's names, and with a
      # `door` — `(calls, declared) → kind` — the kind it answers for the script as a compose call.
      def read(id, door: nil)
        Corpus.read(id).flat_map do |group|
          group.entries.map { |entry| row(id, entry, group, door) }
        end
      end

      def row(id, entry, group, door)
        built = Nexus::Compose::Evaluator.call(script: entry.script, params: entry.params, tool_names: group.tool_names)
        reading = { "corpus" => id, "id" => entry.id, "built" => built.built? }
        reading = reading.merge("bucket" => ComposeBench::Buckets.loud(built.refusal, built.detail)) unless built.built?
        door ? reading.merge(kind_of(entry, group, door)) : reading
      end

      # A raise is the finding itself, kept as the row's `door_error` rather than ending the reading.
      def kind_of(entry, group, door)
        arguments = { "script" => entry.script }.merge(entry.params.empty? ? {} : { "params" => entry.params })
        call = { "id" => "call_1", "name" => "compose", "arguments" => JSON.generate(arguments) }
        { "door_kind" => door.call([call], group.declarations) }
      rescue StandardError => error
        { "door_error" => "#{error.class}: #{error.message.lines.first.to_s.strip}" }
      end

      def rows_of(rows, id) = rows.select { |row| row.fetch("corpus") == id }

      def compared(id, without, with)
        refuse_unread(id, without, with)
        builds = [without, with].map { |rows| rows.select { |row| row.fetch("built") }.map { |row| row.fetch("id") } }
        gained = builds.last - builds.first
        lost = builds.first - builds.last
        if gained.any? || lost.any?
          raise Refused, "over #{id} the with builder builds #{gained.size} scripts the without builder refuses " \
                         "(#{gained.first(3).join("; ")}) and refuses #{lost.size} it builds (#{lost.first(3).join("; ")})"
        end

        broken = with.select { |row| row.key?("door_error") }
        raise Refused, "over #{id} Door.kind raised on #{broken.size} scripts: #{broken.first(3).map { |row| "#{row["id"]}: #{row["door_error"]}" }.join("; ")}" if broken.any?

        [["counterfactual.#{id}", "scripts #{with.size}, builds #{builds.last.size} in both trees; #{listed(without, with)}"],
         *moved(id, without, with), ["counterfactual.#{id}.door_kind", tally(with.map { |row| row.fetch("door_kind") })]]
      end

      # Both trees read the same tracked corpus; a tree that read another count of scripts read
      # another corpus.
      def refuse_unread(id, without, with)
        ids = [without, with].map { |rows| rows.map { |row| row.fetch("id") } }
        raise Refused, "over #{id} the trees read #{ids.first.size} and #{ids.last.size} scripts" unless ids.first.sort == ids.last.sort && ids.first.any?
      end

      # Every listed refusal in either tree, as its bucket there → its bucket here. The builds agree
      # by now, so a script refused in one tree is refused in the other.
      def listed(without, with)
        before = without.to_h { |row| [row.fetch("id"), row.fetch("bucket", nil)] }
        moves = with.filter_map do |row|
          old = before.fetch(row.fetch("id"))
          new = row.fetch("bucket", nil)
          "#{old} → #{new}" if LISTED.include?(old) || LISTED.include?(new)
        end
        "listed refusals old → new: #{moves.empty? ? "none" : tally(moves)}"
      end

      # The scripts whose refusal a builder repair reworded, one by one.
      def moved(id, without, with)
        before = without.to_h { |row| [row.fetch("id"), row.fetch("bucket", nil)] }
        changed = with.reject { |row| before.fetch(row.fetch("id")) == row.fetch("bucket", nil) }
        changed.empty? ? [] : [["counterfactual.#{id}.moved", changed.map { |row| "#{row["id"]} (#{before.fetch(row["id"])} → #{row["bucket"]})" }.join("; ")]]
      end

      def tally(values) = values.tally.sort_by { |value, count| [-count, value] }.map { |value, count| "#{value} #{count}" }.join(", ")

      private_class_method :run, :row, :kind_of, :rows_of, :compared, :refuse_unread, :listed, :moved, :tally
    end
  end
end
