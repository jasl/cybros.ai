require "test_helper"
require "support/live_journey"
require "json"

# WHAT A CONSOLE WILL RENDER, read through the only API a browser on this
# machine can reach. The daemon holds the credential; a page served from it
# is same-origin and never has to hold a member token, and a terminal gets
# the same bytes — which is what makes the shape debuggable before any UI
# exists.
#
# The assertions are about REAL rounds: a model that read a file and
# answered from it, so the transcript carries a call with its own name and
# an output preview, and the task read carries the arguments that call was
# given. A mock cannot produce either.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveConsoleReadsTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  SECRET = "console-reads-#{SecureRandom.hex(4)}".freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-console-e2e")
  def teardown = finish_live_journey!

  def test_the_transcript_and_a_task_read_carry_what_a_console_must_show
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    File.write(File.join(project, "note.txt"), "#{SECRET}\n")
    @daemon.control(:post, "/environment", body: { root: project })

    prompt = "Read note.txt with the read tool and reply with its contents, nothing else."
    output, status = @daemon.cli("do", prompt, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    loop_id = output[/^loop:\s+(\S+)/, 1]

    # THE SAME EVENTS, PUSHED. A page cannot poll a snapshot for a round's
    # text as it arrives, so this is the channel it will hold open —
    # driven here through the terminal, so the shape is debuggable before
    # any UI exists.
    follower = @daemon.cli_background("follow", loop_id)
    watched = +""
    reader = Thread.new { watched << follower.read.to_s.force_encoding(Encoding::UTF_8).scrub }

    done = await_loop_completion(loop_id)
    assert_equal "completed", done.fetch("status"), summarize(done)

    assert reader.join(45), "follow never ended, so a settled loop still looks live"
    follower.close
    assert_match(/\(stream ended: turn_settled\)/, watched, watched)
    assert_match(/^status:\s+completed$/, watched, watched)
    assert_match(/^\s+completed\s+\S/, watched,
      "a task reaching its end is pushed, not polled for:\n#{watched}")

    # THE TRANSCRIPT: rounds in reading order, each with the calls it made.
    transcript, status = @daemon.cli("transcript", loop_id)
    assert_predicate status, :success?, transcript
    report(transcript)
    assert_match(/^\s+- read completed/, transcript, transcript)
    assert_match(/#{Regexp.escape(SECRET)}/, transcript,
      "the call's own output preview is what a scrollback row shows")
    refute_match(/… 0 more calls/, transcript, "a round with nothing hidden says nothing")

    # THE PERSON'S OWN WORDS, read back — the thing that was stored and unreadable until the read
    # models landed. Under a conversation the seed's `prompt` is the turn's SEALED REQUEST — the
    # inline system lead, then the words as the final user message, one canonical-JSON entry per
    # line — not the bare text a standalone loop was authored with. The property is the same: what
    # was stored is readable, and it is exactly what the person typed.
    seed = done.fetch("tasks").find { |task| task.fetch("kind") == "model_task" }
    asked, status = @daemon.cli("task", loop_id, seed.fetch("key"))
    assert_predicate status, :success?, asked
    assert_match(/^asked:\s+\{/, asked, asked)
    assert_equal prompt, final_user_message(asked),
      "the person's words are the final user message of the sealed request:\n#{asked}"

    # AND WHAT A CALL WAS ASKED TO RUN, which no reader could see before.
    # The trace compacts: a task with no tool name omits the key entirely,
    # which is the reading rule the whole projection follows.
    call = done.fetch("tasks").find { |task| task["tool_name"] == "read" }
    refute_nil call, "the model was told to use the read tool: #{done.fetch("tasks").inspect}"
    detail, status = @daemon.cli("task", loop_id, call.fetch("key"))
    assert_predicate status, :success?, detail
    assert_match(/^tool:\s+read$/, detail, detail)
    assert_match(/^input:\s+\{.*note\.txt/, detail, detail)
    assert_match(/#{Regexp.escape(SECRET)}/, detail, "and the output it produced")
  end

  private

    # The `asked:` line and what follows it, read as the sealed request's
    # entries: the text of the LAST user message, which is where a
    # direct_reply's words ride (conversations.md, "where a direct_reply's
    # words live"). Whatever the CLI prints after the request — the round's
    # own output, say — is not an entry and is skipped.
    def final_user_message(asked)
      lines = asked.lines.drop_while { |line| !line.start_with?("asked:") }
      entries = lines.map { |line| line.sub(/\Aasked:\s+/, "").strip }.filter_map do |line|
        JSON.parse(line) if line.start_with?("{")
      rescue JSON::ParserError
        nil
      end
      user = entries.reverse.find { |entry| entry["role"] == "user" }
      user&.fetch("parts", [])&.filter_map { |part| part["text"] }&.join
    end

    def report(transcript)
      puts "\n--- live console reads ----------------------------------------"
      puts "model:   #{MODEL}"
      transcript.lines.first(10).each { |line| puts "  #{line.chomp}" }
      puts "--------------------------------------------------------------"
    end
end
