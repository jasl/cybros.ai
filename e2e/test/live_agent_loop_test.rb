require "test_helper"
require "support/live_journey"
require "support/coding_task"
require "shellwords"

# THE WHOLE THING, WITH A REAL MODEL — the evaluation the rest of this
# suite cannot be: every other journey drives the mock, which answers with
# its own input and follows directives, so it can prove the LOOP around a
# transform and never the transform. This one gives a real model a real
# task, on real files, through rho's own tools, and asks whether the work
# actually got done.
#
# Paid, local, opt-in: E2E_LIVE=1, and the account needs the key of the model's
# provider (`DEEPSEEK_API_KEY` for the default floor; `E2E::ProviderLanes::KEY_NAMES`).
# The models are flash-tier on purpose — a coding loop that costs real
# thought about money is one nobody runs.
class LiveAgentLoopTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze

  # A SMALL PIECE OF REAL DEVELOPMENT WORK: write a file, run it, read what
  # it printed. It needs at least three rounds and two different tools, so
  # a model that calls one tool and stops does not pass by accident. The
  # text is the harness's (`E2E::CODING_TASK`): `live_rho_runner` gives a
  # runner-mode rho the same turn to the byte.
  TASK = E2E::CODING_TASK

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-e2e")

  def teardown = finish_live_journey!

  def test_a_real_model_does_a_real_piece_of_work_through_rhos_tools
    connect_and_open_lane!

    # THE DIRECTORY IT IS TOLD ABOUT is not the runner's root, which is
    # the case that matters: the environment is a statement rather than a
    # boundary, so the model must use what it was told without anything
    # confining it.
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)

    # POINT THE TOOLS AT IT, rather than only telling the model about it.
    # The previous run of this journey proved the difference: told "you
    # work in X, relative paths land elsewhere, use absolute paths there",
    # a real model wrote a relative path and the file went to the runner
    # root. Pointing the runner makes the statement true instead of
    # asking the model to compensate for it — and it constrains nothing,
    # because absolute paths still reach anywhere on the machine.
    pointed = @daemon.control(:post, "/environment", body: { root: project })
    assert_equal project, pointed.dig("environment", "root")

    started = @daemon.control(:post, "/loops",
      body: { prompt: TASK, model: MODEL, working_directory: project })
    loop_public_id = started.dig("loop", "public_id")
    refute_nil loop_public_id, "rho answered #{started.inspect}"

    completed = await_loop_completion(loop_public_id)

    # WHAT THE MODEL DID, printed whatever the verdict — an evaluation that
    # only says pass/fail teaches nothing about the harness.
    report(completed)

    assert_equal "completed", completed.fetch("status"),
      "the loop did not finish: #{summarize(completed)}"
    # THE TURN SHAPE BESIDE THE ROW: a standalone loop renders the conversation's vocabulary over
    # its own rows, and hosts its own waiting room — empty, because the loop completed only once
    # nothing was queued.
    assert_equal "completed", completed.dig("turn", "status"), completed.fetch("turn").inspect
    assert_equal 0, completed.dig("input_queue", "held"), completed.fetch("input_queue").inspect

    # THE PROOF IS ON DISK, not in the transcript. A model that narrates
    # writing a file and never writes one is exactly the failure a
    # transcript assertion cannot see.
    # WHERE IT LANDED IS AN OPEN QUESTION, and this test records the
    # answer rather than asserting the one we want. Told "you are working
    # in #{project}, which is NOT where relative paths land — use absolute
    # paths there", a real model wrote a relative path anyway and the file
    # went to the runner root. That is the first live evidence that
    # telling a model where it is does not make it work there, and the
    # decision it forces is the owner's: an environment that constrains
    # nothing cannot make this impossible, so either the runner's root
    # follows the environment or the model must comply and be measured.
    written = File.join(project, "fizzbuzz.rb")
    assert_path_exists written,
      "the tools were pointed at #{project} and the work landed somewhere else"
    source = File.read(written)
    assert_match(/def fizzbuzz/, source)

    # And it must actually be correct — the task is the specification.
    output = `ruby #{Shellwords.escape(written)} 2>&1`
    assert_equal %w[1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz],
      output.split("\n").map(&:strip), "the program it wrote does not do the job"

    # THE DAEMON WATCHED THE SAME RUN. Until now rho started a loop and
    # then knew nothing about it — the minutes in between were a blank
    # terminal, and every fact in this test came from polling the kernel
    # directly. The follower is the operator's half, and this is the only
    # place it meets a real stream: a fake feed can prove the state
    # machine, never that the daemon subscribed to a stream nexus
    # actually broadcasts on.
    followed = @daemon.control(:get, "/loops").fetch("loops")
      .find { |row| row.fetch("public_id") == loop_public_id }
    refute_nil followed, "the daemon started the loop and never followed it"
    assert followed.fetch("complete"), "the follower never saw it finish"
    assert_equal completed.fetch("status"), followed.fetch("status")
    assert_operator followed.fetch("sequence"), :>, 0,
      "the follower advanced no position, so it received nothing"

    # And it saw the SAME tasks, by the same keys — the vocabulary is
    # task-grained on both sides or the console is showing a different run.
    kernel_keys = completed.fetch("tasks").map { |task| task.fetch("key") }.sort
    assert_equal kernel_keys, followed.fetch("tasks").map { |t| t.fetch("task_key") }.sort

    tools_used = completed.fetch("tasks")
      .select { |task| task.fetch("kind") == "tool_task" }
      .map { |task| task.fetch("tool_name") }
    assert_includes tools_used, "write"
    assert_includes tools_used, "bash", "it never ran what it wrote"
  end

  private






    # rho's execution root for the connected identity.
    def work_root
      user = @daemon.status.dig("identity", "user_public_id")
      refute_nil user, "the daemon reports no identity"
      File.join(@home, "work", "users", user)
    end



    def report(row)
      puts "\n--- live agent loop -------------------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "rounds: #{row.fetch("tasks").count { |t| t.fetch("kind") == "model_task" }}"
      puts "tools:  #{summarize(row)}"
      puts "---------------------------------------------------------------"
    end
end
