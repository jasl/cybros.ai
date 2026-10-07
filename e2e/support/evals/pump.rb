require_relative "../exit_long_pump"

module E2E
  module Evals
    # ONE PUMP, THREE POLICIES: `live_exit_long`'s `decide_every_park!` (`:396-439`) generalized
    # over a POLICY — the scripted human under `--approval ask`, answering every park through rho's
    # own verbs. `approve_all` approves every park; `exit_long` denies a shell read of the vector
    # corpus (`E2E::ExitLongPump.bypass?`) with its reason; `first_differs_denied` is
    # live_approval's person (`live_approval_test.rb:144-149`): the first park approved, the first
    # later park whose command differs denied with the reason, every later park approved. A re-park
    # is approved once more, as a person would after reading `rho task` again. The model's own
    # `ask` is the run's, as on every wait of a model's turn: the park loop draws it on the run's
    # one answer through the watch attendant's door (`attend_followed_ask` — the bench's sentence,
    # then `needs_person` at the next, the run stopped where it is raised). Any
    # other hold the pump cannot answer, or the deadline, RAISES — the lane records it, it never
    # tunes around it.
    module Pump
      Park = Data.define(:key, :tool, :argument, :verb) do
        def to_h = { "key" => key, "tool" => tool, "argument" => argument, "verb" => verb }
      end

      # `decide.call(tool_name, input, parks)` answers "approve" or "deny".
      Policy = Data.define(:name, :reason, :decide)

      APPROVAL_REASON = "do not write 'second'; run: printf changed > second.txt".freeze

      POLICIES = {
        "approve_all" => Policy.new(name: "approve_all", reason: nil, decide: ->(_tool, _input, _parks) { "approve" }),
        "exit_long" => Policy.new(name: "exit_long", reason: ExitLongPump::REASON,
          decide: ->(tool, input, _parks) { ExitLongPump.bypass?(tool, input) ? "deny" : "approve" }),
        "first_differs_denied" => Policy.new(name: "first_differs_denied", reason: APPROVAL_REASON,
          decide: lambda do |_tool, input, parks|
            command = Hash(input)["command"].to_s
            next "approve" if parks.empty? || parks.any? { |park| park.verb == "deny" }

            command == parks.find { |park| park.verb == "approve" }&.argument ? "approve" : "deny"
          end),
      }.freeze

      def self.policy(name) = POLICIES.fetch(name.to_s) { raise ArgumentError, "no pump policy #{name.inspect}: #{POLICIES.keys.join(", ")}" }

      # Polls the daemon's own row every two seconds and answers each new park; returns the parks
      # when the row is complete. THE PARKS ARE THE CALLER'S ARRAY: a stop raised out of this loop —
      # the deadline here, the cost stop off the spend watch — left them in a local, and kimi
      # exit-long #2's record read `parks: nil` over 63 decided parks; the caller keeps the array
      # and salvages it.
      def decide_every_park!(loop_id, policy:, deadline:, parks: [])
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        loop do
          row = followed(loop_id)
          return parks if row && row["complete"]

          reason = row&.dig("attention", "reason")
          if reason == "approval_required"
            Array(row.dig("attention", "blocked_task_keys")).each do |key|
              next if parks.any? { |park| park.key == key }

              parks << decide_one!(loop_id, key, policy, parks)
            end
          elsif reason == MemberPlane::ASKING_REASON
            attend_followed_ask(loop_id)
          elsif reason
            raise "the loop holds for something the pump cannot answer (#{reason}): #{summarize(loop_row(loop_id))}"
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit
            raise Stopped.new("deadline", "the loop never completed under the pump; #{parks.size} parks; #{summarize(loop_row(loop_id))}")
          end

          sleep 2
        end
      end

      # The denial's line is the verb's own contract (live_approval pins the
      # same `failed (approval_denied)`); the reason is positional —
      # `deny LOOP_ID TASK_KEY [REASON]`.
      def decide_one!(loop_id, key, policy, parks)
        detail = task_detail(loop_id, key)
        input = Hash(detail["tool_input"])
        argument = (input["command"] || input["path"] || input["id"] || input["pattern"]).to_s
        verb = policy.decide.call(detail["tool_name"], input, parks)
        puts "park:    #{key}  #{detail["tool_name"]} #{argument[0, 80].inspect}  → #{verb}"
        if verb == "deny"
          printed = run_verb!("deny", loop_id, key, *[policy.reason].compact)
          assert_match(/^status:\s+failed \(approval_denied\)$/, printed, printed)
        else
          printed = run_verb!("approve", loop_id, key)
          printed = run_verb!("approve", loop_id, key) if printed.match?(/^status:\s+needs_approval/)
          assert_match(/^status:\s+(dispatched|running)$/, printed, printed)
        end
        Park.new(key: key, tool: detail["tool_name"], argument: argument, verb: verb)
      end

      def run_verb!(verb, loop_id, key, *rest)
        printed, status = @daemon.cli(verb, loop_id, key, *rest)
        assert_predicate status, :success?, "rho #{verb} failed:\n#{printed}"
        printed
      end

      # The pump's facts on the record: how many parks, how many denied,
      # the tools parked, every park.
      def park_facts(parks)
        { "parks" => parks.size, "denied" => parks.count { |park| park.verb == "deny" },
          "parked_tools" => parks.map(&:tool).tally, "park_list" => parks.map(&:to_h) }
      end
    end
  end
end
