require_relative "door"

module E2E
  module TaskBench
    # Delegation objectives score the first non-read message. The fixtures provide every file
    # mentioned by each request so a preliminary read never contradicts the scoring premise.
    module Objectives
      DOOR_FIXTURES = File.expand_path("fixtures", __dir__)
      # What D4P's task must name to be the suite.
      SUITE = %r{test/all\.rb|suite}i

      module_function

      # A fixture directory as the emulator writes one back: each file's path under it → its bytes,
      # read as UTF-8 by name (the harness inherits the machine's empty locale).
      def door_fixture(id)
        root = File.join(DOOR_FIXTURES, id)
        raise ArgumentError, "no fixture directory for #{id}" unless Dir.exist?(root)

        Dir.glob("**/*", base: root).sort.select { |path| File.file?(File.join(root, path)) }
          .to_h { |path| [path, File.read(File.join(root, path), encoding: Encoding::UTF_8)] }
      end

      def task_fan?(door, size) = door.kind == Door::TASK_FAN && door.members >= size

      def fan_door(calls, size)
        right = task_fan?(Door.kind(calls), size)
        { "pass" => right, "right_door" => right, "acceptable_door" => false }
      end

      D1P = Objective.new(
        id: "D1P", slug: "claims-disproved-in-pairs", fixture: door_fixture("D1P"),
        text: <<~'TEXT',
          Six claims about lib/ledger.rb, lib/posting.rb and lib/balance.rb are listed below. For each claim, two fresh agents — each seeing only the claim and the code — try to disprove it; a claim is sound only if both fail. Do not rule on the claims yourself: hand the disproving out and collect what they find. Reply with one line per claim, `C<n>: sound` or `C<n>: broken`.
          C1 `Ledger#post` rejects a posting whose amount is zero.
          C2 `Balance.for` sums only postings whose `settled` flag is true.
          C3 `Posting#reverse` returns a new posting and leaves the original unchanged.
          C4 `Ledger#post` is idempotent on a posting's `id`.
          C5 `Balance.for` raises when the account is unknown.
          C6 `Posting.new` normalises its currency code to upper case.
        TEXT
        scorer: ->(calls, declared) { fan_door(calls, 6) }
      )

      D2P = Objective.new(
        id: "D2P", slug: "three-scores-added-up", fixture: door_fixture("D2P"),
        text: "docs/date_format.md describes a date format; lib/fmt_a.rb and lib/fmt_b.rb are two candidate implementations. " \
              "Three fresh agents each take the doc and both files and score both candidates against it; a fourth agent adds up " \
              "the three scores and makes the pick. Do not score them yourself. Reply `pick: fmt_a` or `pick: fmt_b`.",
        scorer: ->(calls, declared) { fan_door(calls, 3) }
      )

      D4P = Objective.new(
        id: "D4P", slug: "suite-in-the-background", fixture: door_fixture("D4P"),
        text: "Kick off the full suite, `ruby test/all.rb`, in the background now; it is slow and I do not want you waiting on it. " \
              "Meanwhile tell me how many Ruby sources sit under lib/ — reply with just that number, and do not let the suite delay " \
              "your reply.",
        scorer: lambda do |calls, _declared|
          door = Door.kind(calls)
          task = calls.find(&:task?)
          names_the_suite = SUITE.match?(task&.argument("prompt").to_s)
          in_background = !task.nil? && task.background?
          no_process = calls.none? { |call| call.tool == Door::START_PROCESS }
          right = door.kind == Door::TASK_ONE && in_background && names_the_suite && no_process
          { "pass" => right, "right_door" => right, "acceptable_door" => false, "names_the_suite" => names_the_suite,
            "task_in_background" => in_background, "no_start_process" => no_process }
        end
      )

      D3P = Objective.new(
        id: "D3P", slug: "five-finders-gathered", fixture: door_fixture("D3P"),
        text: "lib/a.rb, lib/b.rb, lib/c.rb, lib/d.rb and lib/e.rb each define one method that is unused anywhere under lib/. " \
              "Hand each of the five to its own fresh agent, all at the same time, to find that method; then gather what the " \
              "five report into one reply, a line for each: `lib/<x>.rb — <method>`.",
        scorer: lambda do |calls, _declared|
          door = Door.kind(calls)
          right = task_fan?(door, 5)
          { "pass" => right, "right_door" => right, "acceptable_door" => false }
        end
      )

      DOOR = [D1P, D2P, D4P, D3P].freeze
    end
  end
end
