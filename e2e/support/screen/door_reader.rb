require "json"
require "yaml"
require_relative "../task_bench/look"
require_relative "corpus"
require_relative "job"

module E2E
  module Screen
    # Read the authored corpus with the task bench's look and door rules. The first round that
    # is not a look is the door; three looks are a scout. Comparing the tally with a definition's
    # expected labels catches classification changes before a screen runs.
    #
    # Compose scripts use the union of declared tools. A built compose label includes the number
    # of model leaves read by a step, alongside its kind and scored round.
    module DoorReader
      CLI = "support/screen/door_reader_cli.rb".freeze
      SCOUT = "scout".freeze

      module_function

      # The reading in the with tree against the register; the stamp's lines, or a refusal naming
      # the first (bench, task, model) that differs.
      def call(definition:, trees:, command: CAPTURE)
        root = trees.fetch("with")
        out, ok, err = command.call(["bundle", "exec", "ruby", CLI], chdir: File.join(root, "e2e"))
        raise Refused, "the door reader could not run in #{root}: #{err.to_s.lines.last(3).join.strip}" unless ok

        read = JSON.parse(out)
        registered = register(definition)
        differing = differences(registered, read)
        if differing.any?
          raise Refused, "the door reader differs from the register on #{differing.size} of #{registered.size} (bench, task, model): " \
                         "#{differing.first(3).join("; ")}"
        end

        [["door_reader", "the register holds: #{summary(read)}"]]
      end

      # The definition's registered tally: `(bench task model) => { label => count }`.
      def register(definition)
        YAML.safe_load_file(File.join(definition.dir, definition.stage0.fetch("door_reader").fetch("expected")))
      end

      # THE TALLY: each record's label counted under its (bench, task, model). `door` answers a
      # round's kind — `(calls, declared) → Door`, a value with `kind`, `built` and `members`.
      def tally(records, door:, declared:)
        counted = records.group_by { |record| key(record) }.transform_values do |own|
          own.map { |record| label(record, door: door, declared: declared) }.tally.sort.to_h
        end
        counted.sort.to_h
      end

      def label(record, door:, declared:)
        rounds = record.fetch("rounds")
        index = rounds.index { |round| !look?(round) }
        if index
          kinded = door.call(TaskBench::Look.calls(rounds[index]), declared)
          "#{kinded.kind}@r#{index + 1}#{" members=#{kinded.members}" if built_compose?(kinded)}"
        else
          SCOUT
        end
      end

      # The register's own spelling of a record: the task's family shortened (`t-`, `w-`), the
      # model's last segment.
      def key(record)
        task = record.fetch("task").sub(/\Atask-/, "t-").sub(/\Aworkflow-/, "w-")
        "#{record.fetch("bench")} #{task} #{record.fetch("model").split("/").last}"
      end

      def look?(round) = TaskBench::Look.look?(round)

      def built_compose?(kinded) = kinded.kind.start_with?("compose_") && kinded.built == true

      # The union of the declared sets' entries, one per name, in the order first declared.
      def declared = Corpus.declared_sets.flat_map { |row| row.fetch("declarations") }.uniq { |entry| entry.dig("function", "name") }

      # Every (bench, task, model) whose registered tally is not the one read, both sides named.
      def differences(registered, read)
        (registered.keys | read.keys).sort.filter_map do |name|
          unless registered[name] == read[name]
            "#{name}: registered #{registered[name].inspect}, read #{read[name].inspect}"
          end
        end
      end

      # The kinds and the rounds the door was scored at, over every record read.
      def summary(read)
        labels = read.values.flat_map { |own| own.flat_map { |label, count| [label] * count } }
        kinds = labels.map { |label| label[/\A[a-z_]+/] }.tally.sort.to_h
        rounds = labels.map { |label| label[/@r(\d+)/, 1]&.then { |round| "round #{round}" } || SCOUT }.tally.sort.to_h
        "#{labels.size} records; #{kinds.map { |kind, count| "#{kind} #{count}" }.join(", ")}; scored at " \
          "#{rounds.map { |round, count| "#{round}: #{count}" }.join(", ")}"
      end

      private_class_method :built_compose?, :differences, :summary
    end
  end
end
