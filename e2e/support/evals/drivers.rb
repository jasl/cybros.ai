require "net/http"
require "securerandom"

module E2E
  module Evals
    # THE DRIVERS ARE THE LANES' DRIVERS, MOVED: each opens the loop THROUGH THE BINARY (`rho do`
    # with the task's flags) and scripts the one human step its shape needs, then names the loop(s)
    # to trace. `plain`, `answer_ask`, `until`, `say_second_turn`, `brake`, `compact_queued_round`,
    # `halting_loop` are `live_gallery_test.rb:149-249`'s verbatim over a `Task`; `handoff` is
    # `live_handoff_test.rb:59-79`'s (a second runner-mode home the lane started); `pump` is
    # `live_exit_long`'s scripted human over a `Pump::Policy`. V2 adds the three no lane had:
    # `settle_receipts` (the workflow family and task-fan-five: a plain turn, then every loop the
    # receipts woke, until the conversation is quiet), `memory_scope` (live_memory_scopes' steward
    # read and second workspace, as facts) and `processes` (live_processes' person's half, as
    # facts). A driver reads `@model`, `@runner_id` and the task's `deadline_seconds`; what it saw
    # that no route serves goes on the run's FACTS — the reply `rho result` printed rides every
    # plain run, so a predicate can read what the model answered. A driver that raises is one
    # record (the lane catches it), never a lost run.
    module Drivers
      Run = Data.define(:loop, :conversation, :extra_loops, :facts) do
        def self.one(loop_id, conversation, facts = {}) = new(loop: loop_id, conversation: conversation, extra_loops: [], facts: facts)
      end

      # `@tree_runner` names the runner serving the tree when it is not the host's own — a container
      # family's (the lane sets it per group). EVERY WAIT OF A RUN SHARES THE ONE ANSWER: outside
      # answer_ask's scripted person, no driver scripts a person for the model's own `ask`, so every
      # wait on a model's turn in the run's conversation — the plain turn, the woken turn, the
      # person's turn 2, a receipt-woken loop, a detached branch still settling, the pump's park loop,
      # each driver's wait after its scripted step, and turn 1's `rho watch` in `until`,
      # `say_second_turn` and `handoff` — answers the run's first ask with the bench's own sentence
      # and ends the run at the next as `needs_person` (`await_loop_completion_unattended`, the quiet
      # read, the tasks-settled read, `decide_every_park!`, `watch_the_turn`'s attendant beside the
      # watch) instead of idling to the deadline; what was asked and what was answered ride the
      # record's facts. The watch runs on through an answered ask, so its `background:` and `check`
      # lines cover the whole turn, and its timeout is the task's deadline, shared with the settle
      # after it. The scripted steps stay scripted: answer_ask's person, the pump's parks, the
      # halting loop's authored gates. The one model's turn no wait attends is outside the run's
      # conversation: `memory_scope`'s reply in a second workspace (`ask_in_another_workspace`),
      # where an ask is the lane's error once its 300 s pass.
      def drive_plain(task, project, _seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags, runner: @tree_runner)
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        # A compose the model left detached completes the row while its
        # branch still runs; the trace is read once every task has settled.
        await_tasks_settled(loop_id, deadline: task.deadline_seconds)
        Run.one(loop_id, conversation, "reply" => result_of(loop_id))
      end

      # The workflow family's door, and task-fan-five's: a plain turn whose
      # reply may go final while its branches run, each receipt waking a
      # turn that may start more — the trace is read once the conversation
      # is QUIET, with every woken loop beside the primary and each loop's
      # reply on the facts.
      def drive_settle_receipts(task, project, _seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        rows = await_conversation_quiet(conversation, deadline: task.deadline_seconds)
        woken = rows.map { |row| row.fetch("public_id") } - [loop_id]
        replies = [loop_id, *woken].to_h { |id| [id, result_of(id)] }
        puts "woken:   #{woken.size} loop(s) after the primary"
        Run.new(loop: loop_id, conversation: conversation, extra_loops: woken,
          facts: { "reply" => replies.values.last, "replies" => replies, "woken_loops" => woken })
      end

      # The person answers the ask with the seed's secret — a word the
      # model cannot guess; the verification reads it back off the disk.
      def drive_answer_ask(task, project, seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        asking = await_attention(loop_id, deadline: 300)
        key = Array(asking.dig("attention", "blocked_task_keys")).first
        refute_nil key, "the ask named no task to answer: #{asking.inspect}"
        prompt = task_detail(loop_id, key)["prompt"]
        puts "asked:   #{key} #{prompt.inspect}"
        answered, status = @daemon.cli("answer", loop_id, key, seed.secret)
        assert_predicate status, :success?, "rho answer failed:\n#{answered}"
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        Run.one(loop_id, conversation, "asked_key" => key, "asked_prompt" => prompt.to_s[0, 200], "reply" => result_of(loop_id))
      end

      # live_repair's shape, verbatim: the halt is authored over the member
      # plane, the person abandons one gate and retries the other.
      def drive_halting_loop(task, _project, _seed)
        loop_id, tokens = author_halting_loop!(@model)
        await_halt(loop_id, deadline: task.deadline_seconds)
        abandoned, status = @daemon.cli("abandon", loop_id, "gate-1")
        assert_predicate status, :success?, abandoned
        retried, status = @daemon.cli("retry", loop_id)
        assert_predicate status, :success?, "one candidate left, so no key was needed:\n#{retried}"
        answered, status = @daemon.cli("answer", loop_id, "gate-2", "go ahead", "--token", tokens.fetch("gate-2"))
        assert_predicate status, :success?, answered
        await_loop_completion(loop_id, deadline: task.deadline_seconds)
        Run.one(loop_id, nil)
      end

      def drive_compact_queued_round(task, project, _seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        door = compact_a_queued_round!(loop_id, deadline: task.deadline_seconds)
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        Run.one(loop_id, conversation, "compacted_round" => door["task_key"], "summary_key" => door["summary_task_key"],
          "reply" => result_of(loop_id))
      end

      # `rho do --until` prints its ladder line; the flags are the task's.
      # The watch is the run's whole deadline, the spend and the model's ask
      # attended beside it (`watch_the_turn`), so its check lines cover the
      # whole ladder — and a stop keeps the ones printed before it.
      def drive_until(task, project, _seed)
        refute_nil task.flags["until"], "an until task names its check in flags.until"
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        attempts = task.flags.fetch("attempts", 5)
        assert_match(/^until:\s+#{Regexp.escape(task.flags["until"])} \(#{attempts} checks, in #{Regexp.escape(project)}\)/,
          last_do_output, last_do_output)
        watch_the_turn(loop_id, deadline: task.deadline_seconds,
          watch_facts: ->(watched) { { "checks" => watched.scan(/check \d\/\d: [^\n]+/) } })
        Run.one(loop_id, conversation, "reply" => result_of(loop_id), "checks" => opened.facts.fetch("checks"))
      end

      # live_task_mail's `mail`: the reply goes final with the suite still
      # running, the kernel mails the receipt, the mail wakes a second loop.
      # With no `turns:` the shape IS the two loops (the gallery's
      # detached_receipt); with one, the person's turn 2 is said once the
      # woken turn ended (a steer would land inside it) and its facts are
      # live_task_mail's reach columns: the mail in turn 2's history, the
      # reply, whether the suite was re-run. No `task` call: the predicate's
      # first line is the finding, answered now with no mail to wait 300 s for.
      # Every call `wake: "passive"` (`passive_wake?`): the receipt is history
      # and wakes nothing, so no woken turn is awaited — the model's choice,
      # on the record as `wake_passive`. Each fact is STASHED as it is
      # learned, so a stop in a later wait — the deadline, or a woken turn
      # asking after the run's answer was spent — salvages what the driver
      # already saw; the watch's `background:` line is stashed as the watch
      # returns (`watch_the_turn`), so a stop during turn 1 keeps it too.
      def drive_say_second_turn(task, project, _seed)
        conversation, loop_one = open_turn(task.instruction, project, model: @model, flags: task.flags)
        _watched, row = watch_the_turn(loop_one, deadline: task.deadline_seconds,
          watch_facts: ->(watched) { { "reply_final_with_background" => watched.match?(/^background: /) } })
        background = opened.facts.fetch("reply_final_with_background")
        puts "watch:   background line #{background ? "present" : "ABSENT"}"
        facts = { "reply_final_with_background" => background, "reply" => result_of(loop_one),
                  "turn_1_called" => row.fetch("tasks").filter_map { |t| t["tool_name"] }.tally }
        stash_facts_on_opened(facts)
        calls = row.fetch("tasks").select { |t| t["tool_name"] == "task" }
        if calls.empty?
          puts "no task: #{summarize(row)}"
          return Run.one(loop_one, conversation, facts.merge("task_started" => false, "mailed" => false, "receipt_woke_a_turn" => false))
        end
        mailed = await_mail(conversation, deadline: 300)
        passive = passive_wake?(loop_one, calls)
        facts = facts.merge("task_started" => true, "mailed" => !mailed.nil?, "wake_passive" => passive)
        stash_facts_on_opened(facts)
        return Run.one(loop_one, conversation, facts.merge("receipt_woke_a_turn" => false)) if mailed.nil?

        await_loop_completion_unattended(loop_one, deadline: task.deadline_seconds)
        woken = passive ? [] : [await_next_turn(conversation, after: [loop_one], deadline: 300)]
        facts = facts.merge("receipt_woke_a_turn" => woken.any?)
        stash_facts_on_opened(facts)
        woken.each { |loop_id| await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds) }
        return Run.new(loop: loop_one, conversation: conversation, extra_loops: woken, facts: facts) if task.turns.empty?

        loop_two, more = say_turn_two!(task, conversation, after: [loop_one, *woken])
        Run.new(loop: loop_one, conversation: conversation, extra_loops: [*woken, loop_two], facts: facts.merge(more))
      end

      # A RECEIPT THE MODEL ASKED NOT TO BE WOKEN BY: every one of `calls` said `wake: "passive"`,
      # which records its completion as conversation history and starts no reply (the tool text).
      # Turn 1 is an ordinary reply, whose work defaults to auto, so an omitted wake is auto.
      def passive_wake?(loop_id, calls) = calls.all? { |call| task_input(loop_id, call.fetch("key"))["wake"] == "passive" }

      # The person's turn 2 (`task.turns.first`) through `rho say`; what
      # it did with the mail is read off the timeline, the reply and its
      # bash rows — never off the model's paraphrase.
      def say_turn_two!(task, conversation, after:, origin: "task_result")
        said, status = @daemon.cli("say", conversation, task.turns.first)
        assert_predicate status, :success?, said
        loop_two = await_next_turn(conversation, after: after, deadline: 300)
        done = await_loop_completion_unattended(loop_two, deadline: task.deadline_seconds)
        commands = done.fetch("tasks").select { |t| t["tool_name"] == "bash" }
          .map { |t| task_input(loop_two, t.fetch("key"))["command"].to_s }
        [loop_two, { "turn_2_loop" => loop_two, "turn_2_reply" => result_of(loop_two),
                     "turn_2_bash_commands" => commands, "mail_in_turn_2_history" => mail_before_turn?(conversation, done, origin: origin) }]
      end

      # THE SPAWN FAMILY'S DRIVER: `say_second_turn`'s twin for a SPAWNED child — the reply goes
      # final with the child at work, the kernel mails the child's reply (`origin: child`), the mail
      # wakes a turn; with `turns:` the person's turn 2 is said once the woken turn ended. Its own
      # driver because a detached `spawn` row settles at once — unlike a detached `task`, live until
      # its branch ends — so `settle_receipts`' quiet read would return before the child ever
      # replied; and a spawn that WAITED gets the reply as the call's own result and mails nothing:
      # recorded as `spawn_waited`, nothing awaited. A reply every spawn asked `wake: "passive"` for
      # is history and wakes nothing: `wake_passive`, no woken turn awaited (`passive_wake?`).
      def drive_spawn_reply(task, project, _seed)
        conversation, loop_one = open_turn(task.instruction, project, model: @model, flags: task.flags)
        row = await_loop_completion_unattended(loop_one, deadline: task.deadline_seconds)
        spawns = row.fetch("tasks").select { |t| t["tool_name"] == "spawn" }
        waited = spawns.any? { |t| task_input(loop_one, t.fetch("key"))["wait"] == true }
        facts = { "reply" => result_of(loop_one), "spawn_waited" => waited,
                  "turn_1_called" => row.fetch("tasks").filter_map { |t| t["tool_name"] }.tally }
        stash_facts_on_opened(facts)
        if spawns.empty? || waited
          puts "no detached spawn: #{summarize(row)}"
          return Run.one(loop_one, conversation, facts.merge("child_replied" => false, "reply_woke_a_turn" => false))
        end
        mailed = await_mail(conversation, deadline: 300, origin: "child")
        passive = passive_wake?(loop_one, spawns)
        facts = facts.merge("child_replied" => !mailed.nil?, "wake_passive" => passive)
        stash_facts_on_opened(facts)
        return Run.one(loop_one, conversation, facts.merge("reply_woke_a_turn" => false)) if mailed.nil?

        woken = passive ? [] : [await_next_turn(conversation, after: [loop_one], deadline: 300)]
        facts = facts.merge("reply_woke_a_turn" => woken.any?)
        stash_facts_on_opened(facts)
        woken.each { |loop_id| await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds) }
        return Run.new(loop: loop_one, conversation: conversation, extra_loops: woken, facts: facts) if task.turns.empty?

        loop_two, more = say_turn_two!(task, conversation, after: [loop_one, *woken], origin: "child")
        Run.new(loop: loop_one, conversation: conversation, extra_loops: [*woken, loop_two], facts: facts.merge(more))
      end

      # The brake parks the loop `needs_attention`, which is terminal for a
      # watcher; the trace is read held, then `after_brake` stops it. A
      # model that varies its call never trips the brake and never ends
      # ("do not give up"): the deadline is the finding, and the loop is
      # stopped so the next run starts clean.
      def drive_brake(task, project, _seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        begin
          await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        rescue StandardError
          stop_conversation!(conversation)
          raise
        end
        Run.one(loop_id, conversation)
      end

      def after_brake(run) = stop_conversation!(run.conversation)

      # THE STEP A DRIVER OWES ONCE ITS RUN IS RECORDED, by the driver's name, on whichever Run the
      # run left (opened or answered); a driver not named here owes none, and a run that never
      # opened a turn has nothing to act on.
      AFTER_DRIVE = { "brake" => :after_brake }.freeze

      def after_drive(driver, run)
        hook = AFTER_DRIVE[driver]
        send(hook, run) if hook && run
      end

      # live_handoff's shape: turn 1 on rho's own runner, `rho handoff` to
      # the runner-mode home the lane started (`@runner_id`), the person's
      # turn 2 (`task.turns.first`) on it; the proof of WHERE is on the
      # facts — turn 2's bash rows addressed to and claimed by the runner,
      # rho's own runner idle after the handoff.
      def drive_handoff(task, project, _seed)
        refute_nil @runner_id, "a handoff task needs the runner-mode home (daemon.runner_home: true)"
        assert_equal 1, task.turns.size, "a handoff task says exactly one second turn (turns:)"
        own_runner = @daemon.status.dig("identity", "runner_executor_public_id")
        point_tools!(@runner, project)
        conversation, loop_one = open_turn(task.instruction, project, model: @model, flags: task.flags)
        watch_the_turn(loop_one, deadline: task.deadline_seconds)
        own_claims_before = @daemon.claims.length

        handed, status = @daemon.cli("handoff", conversation, @runner_id)
        assert_predicate status, :success?, "rho handoff failed:\n#{handed}"
        said, status = @daemon.cli("say", conversation, task.turns.first)
        assert_predicate status, :success?, said
        loop_two = await_next_turn(conversation, after: [loop_one], deadline: 300)
        done = await_loop_completion_unattended(loop_two, deadline: task.deadline_seconds)
        bashes = done.fetch("tasks").select { |t| t["tool_name"] == "bash" }
        facts = {
          "handed_off" => handed.lines.first.to_s.start_with?("handed off: #{conversation} → #{@runner_id}"),
          "tree_synced" => !handed.match?(/the tree is not synced/),
          "turn_2_bash_rows" => bashes.size,
          "turn_2_bash_on_runner" => !bashes.empty? && bashes.all? { |t| t.dig("claimed_by", "executor_public_id") == @runner_id },
          "runner_log_claimed_turn_2" => bashes.all? { |t| @runner.claimed_keys.include?(t.fetch("key")) },
          "own_runner_idle_after" => @daemon.claims.length == own_claims_before,
          "own_runner" => own_runner, "runner" => @runner_id,
        }
        Run.new(loop: loop_one, conversation: conversation, extra_loops: [loop_two], facts: facts)
      end

      # The scripted human under `--approval ask`, deciding by the task's policy. The parks are
      # decided UNDER THE SPEND WATCH (the park loop returns only on a complete row, so the exit
      # family had no cost stop — exit-long glm #1 spent $18.71 against $8 with no `stopped`); the
      # stop's `rho stop` completes the row, the park loop returns, and the stop is raised — the
      # `until` driver's shape. THE PARKS OUTLIVE THE STOP: the array is this driver's, filled by
      # the park loop; a `Stopped` — the cost stop off the watch after the loop returned its parks,
      # the deadline from inside it — re-stashes the opened Run with the park facts for `caught`'s
      # salvage, then rides on. kimi exit-long #2 read `parks: nil` over 63 decided parks before
      # this.
      def drive_pump(task, project, _seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        parks = []
        begin
          watching_spend(loop_id) do
            decide_every_park!(loop_id, policy: Pump.policy(task.policy), deadline: task.deadline_seconds, parks: parks)
          end
        rescue Stopped => stop
          stash_facts_on_opened(park_facts(parks))
          raise stop
        end
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        Run.one(loop_id, conversation, park_facts(parks).merge("reply" => result_of(loop_id)))
      end

      # live_memory_scopes' script (`:58-85`): the model saves a note under
      # `user/` through rho's turn; the person's own door (the steward's SDK
      # client) says where it landed; a conversation no loop backs in a
      # SECOND workspace of the same person answers from memory alone. Both
      # are facts the predicate reads; the token is the seed's secret.
      def drive_memory_scope(task, project, seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
        paths = client.profile.memory.list.map(&:path)
        saved = paths.include?("user/token.md") ? client.profile.memory.read("user/token.md").content.to_s : nil
        puts "memory:  #{paths.inspect}"
        reply = ask_in_another_workspace(client, seed)
        Run.one(loop_id, conversation, "reply" => result_of(loop_id), "memory_paths" => paths,
          "note_under_user" => !saved.nil?, "note_carries_token" => saved.to_s.include?(seed.secret),
          "other_workspace_reply" => reply.to_s.strip[0, 200], "other_workspace_carries_token" => reply.to_s.include?(seed.secret))
      end

      def ask_in_another_workspace(client, seed, deadline: 300)
        other = client.workspaces.create(name: "evals memory #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid)
        conversations = client.workspace(other.public_id).conversations
        chat = conversations.conversation(conversations.create(title: "The other workspace", idempotency_key: SecureRandom.uuid).public_id)
        chat.inputs.create(kind: "direct_reply", model: seed.model, idempotency_key: SecureRandom.uuid,
          text: "What word did I ask you to remember? Answer with the word only.")
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        loop do
          turn = chat.turns.list.items.find { |row| row.kind == "direct_reply" }
          return turn.text if turn && %w[completed failed].include?(turn.status)
          raise "the reply never settled in the other workspace" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep 3
        end
      end

      # live_processes' person's half (`:65-77`), as facts: the server the
      # model started is listed under the loop, still answers on the seed's
      # port, its log is under HOME, `rho kill` ends it and the port is free.
      def drive_processes(task, project, seed)
        conversation, loop_id = open_turn(task.instruction, project, model: @model, flags: task.flags)
        await_loop_completion_unattended(loop_id, deadline: task.deadline_seconds)
        listing, = @daemon.cli("processes")
        id = listing[/^(p\d+)  running  pid \d+  owner #{Regexp.escape(loop_id)}/, 1]
        facts = { "reply" => result_of(loop_id), "listed_under_loop" => !id.nil?,
                  "served_on_port" => http_get("http://127.0.0.1:#{seed.port}/hello.txt") }
        return Run.one(loop_id, conversation, facts.merge("killed" => false, "port_freed" => false)) if id.nil?

        logs, = @daemon.cli("logs", id)
        killed, = @daemon.cli("kill", id)
        Run.one(loop_id, conversation, facts.merge(
          "log_under_home" => logs.to_s.match?(%r{^log: #{Regexp.escape(@home)}/}),
          "killed" => killed.to_s.match?(/^#{id}  exited/),
          "port_freed" => http_get("http://127.0.0.1:#{seed.port}/hello.txt").nil?
        ))
      end

      # The body, or nil when nothing answers (Errno::ECONNREFUSED is the proof of a free port).
      def http_get(url)
        Net::HTTP.get(URI(url))
      rescue StandardError
        nil
      end
    end
  end
end
