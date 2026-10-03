require "test_helper"
require "support/live_journey"

# THE MODEL ASKS, A PERSON ANSWERS, THE MODEL USES THE ANSWER.
#
# This is the half of the loop the other live journey cannot reach. There,
# a model is given everything it needs and does the work; here it is given
# a task it CANNOT finish without asking, so the run stops, holds, and
# waits for a human — and only continues because one replied.
#
# It is the first end-to-end exercise of a path that was broken in three
# places at once, in a way no unit test could have shown together: the
# kernel minted an unreachable token for a model's `g.ask` and refused
# every answer, the SDK had no verb to answer with, and rho had no way to
# show that a loop was waiting on anybody.
#
# Paid, local, opt-in: E2E_LIVE=1, and the account needs the key of the model's
# provider (`DEEPSEEK_API_KEY` for the default floor; `E2E::ProviderLanes::KEY_NAMES`).
class LiveHumanInTheLoopTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze

  # THE ANSWER CANNOT BE GUESSED, and that is the whole design of this
  # task. A model that writes the file without asking gets it wrong, so
  # "did it ask" and "did it use the answer" are one assertion on disk.
  SECRET = "marmalade".freeze

  TASK = <<~TEXT.strip.freeze
    Write a file called greeting.txt containing exactly one word: the
    codeword I have in mind. You do not know the codeword and you cannot
    work it out — you must ask me for it.

    Ask by calling the `ask` tool, and nothing else:

      ask({prompt: "What is the codeword?"})

    Your next round will receive my answer as an <answer> block. Then write
    greeting.txt with exactly that word and nothing else, and reply DONE.
  TEXT

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-ask-e2e")

  def teardown = finish_live_journey!

  def test_a_real_model_asks_a_person_and_uses_what_they_answered
    connect_and_open_lane!

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    # THROUGH THE COMMAND, not the route behind it. Every journey before
    # this one drove the daemon's HTTP surface directly, which is why
    # `rho do` could name a timeout constant that was never defined and
    # raise NameError on its first line of real work without anything
    # noticing. A capability is not shipped until the thing a person
    # types does it.
    output, status = @daemon.cli("do", TASK, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    loop_public_id = output[/^loop:\s+(\S+)/, 1]
    refute_nil loop_public_id, "rho do printed no loop id:\n#{output}"
    # That `compose` was offered is proved by the ask below surfacing at all: the 201 names no tools
    # (the declaration is the profile's).

    # THE DAEMON IS WHERE THE ASK SURFACES. Not the kernel: a person
    # watching their machine must be told a model is waiting on them
    # without querying an API by hand, and until this round rho had no
    # opinion about a loop it had started.
    asking = await_ask(loop_public_id)
    task_key = asking.fetch("attention").fetch("blocked_task_keys").first
    refute_nil task_key, "the ask named no task to answer: #{asking.inspect}"
    puts "\n--- the model asked ------------------------------------------"
    puts "reason: #{asking.dig("attention", "reason")}"
    puts "task:   #{task_key}"

    # THE QUESTION IT ACTUALLY ASKED, served from the await's own input
    # body. A person handed a task key and no question cannot answer.
    question = task_prompt(loop_public_id, task_key)
    puts "asked:  #{question.inspect}"
    refute_nil question, "the ask carried no prompt, so nobody could answer it"

    # THE AGENT'S OWN INBOX ROW: a model's ask on a loop rho created is listed on rho's inbox — the
    # daemon noted it — and never claimed. THROUGH THE COMMAND A PERSON ACTUALLY TYPES. No
    # resolution token is presented, because a model's ask was issued none: the row names rho's
    # address, and that is the door — the commit lands on the executor plane, and the CLI says so.
    assert_match(/event=executor\.ask_available loop=#{Regexp.escape(loop_public_id)} task=#{Regexp.escape(task_key)}\b/,
      @daemon.log_text, "rho never noted the ask on its inbox")
    answered, answer_status = @daemon.cli("answer", loop_public_id, task_key, SECRET)
    assert_predicate answer_status, :success?, "rho answer failed:\n#{answered}"
    assert_match(/answered:\s+#{Regexp.escape(task_key)} \(executor plane\)/, answered, answered)

    completed = await_loop_completion(loop_public_id)
    report(completed)
    assert_equal "completed", completed.fetch("status"),
      "the loop did not finish after it was answered: #{summarize(completed)}"

    # AND THE OTHER TWO OPERATOR VERBS, on a run that is now over. `watch`
    # must return rather than hang on a finished loop, and `result` must
    # serve what it produced — the follower deliberately does not keep the
    # text, so this proves the fetch behind it.
    watched, watch_status = rho_watch(loop_public_id)
    assert_predicate watch_status, :success?, "rho watch failed:\n#{watched}"
    assert_match(/status:\s+completed/, watched)

    printed, result_status = @daemon.cli("result", loop_public_id)
    assert_predicate result_status, :success?, "rho result failed:\n#{printed}"
    assert_match(/status:\s+completed/, printed)

    # THE PROOF IS ON DISK. A model that asks, is answered, and then
    # writes something else has not used the answer — and a transcript
    # assertion cannot tell the difference.
    written = File.join(project, "greeting.txt")
    assert_path_exists written, "it never wrote the file"
    assert_equal SECRET, File.read(written).strip,
      "it did not write what the human answered"
  end

  private

    # The daemon's rows are keyed by the HOST — the conversation `rho do` opened — and carry every
    # loop that backed it, so a loop id finds its row through `loops`, the way `rho watch` does.
    def followed(loop_public_id)
      @daemon.control(:get, "/loops").fetch("loops").find do |row|
        row.fetch("public_id") == loop_public_id || Array(row["loops"]).include?(loop_public_id)
      end
    end

    def await_ask(loop_public_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
      loop do
        row = followed(loop_public_id)
        return row if row && row["attention"]
        if row && row["complete"]
          flunk "the loop finished without ever asking: #{row.fetch("status")}"
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "the model never asked: #{row.inspect}"
        end

        sleep 2
      end
    end

    def task_prompt(loop_public_id, task_key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}" \
        "/agent_loops/#{loop_public_id}/tasks/#{task_key}")
        .dig("task", "prompt")
    end





    def report(row)
      puts "\n--- live human in the loop -----------------------------------"
      puts "model:  #{MODEL}"
      puts "status: #{row.fetch("status")}"
      puts "tasks:  #{summarize(row)}"
      puts "--------------------------------------------------------------"
    end
end
