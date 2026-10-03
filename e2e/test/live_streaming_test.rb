require "test_helper"
require "support/live_journey"

# X-D — A REAL MODEL'S WORDS REACH A TERMINAL AS IT WRITES THEM.
#
# Assert streaming on `rho follow`'s own stdout. A separate journey-owned subscription could pass
# while the CLI never opened the transcript feed, hiding a broken user-visible stream.
#
# TWO PROPERTIES, and the second is why the whole printer exists:
#   1. text printed BEFORE the stream ends (a delta, not a settle);
#   2. every structured line still anchored under it — `^status:` is what
#      twenty other paid lanes parse, and a delta leaves the cursor
#      mid-line.
#
# Prefix equality, not equality: a settle whose remainder printed last
# makes the two equal, and a lane demanding equality would go red the
# first time a provider's last coalesced flush lands after the snapshot.
#
# Paid, local, opt-in: E2E_LIVE=1. Both weak models.
class LiveStreamingTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  TEXT_BOUND = 64 * 1024
  # The printer's own gutter (`Rho::StreamPrinter::INDENT`), restated here
  # because e2e drives rho as a PROCESS and loads none of its library: what
  # the model said is exactly the lines that carry this lead, and nothing
  # rho prints itself ever does.
  INDENT = "  \u2502 ".freeze

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-streaming-e2e")
  def teardown = finish_live_journey!

  def test_the_reply_is_printed_as_it_is_written_and_the_status_lines_survive_it
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    # A prompt whose answer is several sentences and calls NO tool: the
    # subject is the text channel, and a tool call would spend the turn
    # somewhere this lane says nothing about.
    output, status = @daemon.cli("do",
      "Explain, in four or five plain sentences and without running anything, " \
      "why a program that reads a file line by line uses less memory than one that reads it whole.",
      "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    loop_id = output[/^loop:\s+(\S+)/, 1]
    refute_nil loop_id, output
    # `rho do` is not a watcher and must never become one: two lanes pin
    # this on the mock, and it holds on a live turn too.
    refute_match(/^status:/, output, "`rho do` returns at the 201; it does not follow")

    followed, follow_status = @daemon.cli("follow", loop_id, "--timeout", "600")
    watched, watch_status = rho_watch(loop_id, "--timeout", "60")
    settled = read_result(loop_id)
    # the one report line every paid lane prints (`LiveJourney#report_loop!`).
    report_loop!(loop_row(loop_id), succeeded: !settled.empty?)

    # THE DIAGNOSTIC IS PRINTED BEFORE THE ASSERTIONS, so a red run still
    # says what the provider and the terminal actually did — which is the
    # only thing a paid lane can tell you that a mock cannot.
    lines = followed.lines
    printed = printed_block(lines)
    puts "live_streaming[#{MODEL}]: printed=#{printed.bytesize}B settled=#{settled.bytesize}B " \
         "watch_printed=#{printed_block(watched.lines).bytesize}B " \
         "remainder=#{settled.bytesize > printed.bytesize} " \
         "restarted=#{followed.include?("(restarted")}"

    assert_predicate follow_status, :success?, followed
    assert_match(/^\(stream ended: turn_settled\)$/, followed,
      "the follow ended on the settled turn, on its own line:\n#{followed}")
    assert_predicate watch_status, :success?, watched
    assert_match(/^status:\s+completed$/, watched,
      "the anchored line every other paid lane parses:\n#{watched}")
    refute_empty settled, "the loop resolved no deliverable to compare against"

    refute_empty printed, "nothing the model said reached the terminal:\n#{followed}"
    first_text = lines.index { |line| line.start_with?(INDENT) }
    ended = lines.index { |line| line.start_with?("(stream ended:") }
    assert_operator first_text, :<, ended,
      "the text has to be on screen BEFORE the stream ends, or it is not streaming:\n#{followed}"
    assert_prefix(settled, printed, followed)
  end

  private

    # The model's words are the GUTTERED block, and nothing else in rho's
    # output carries that lead — which is the whole reason it is a gutter
    # and not two spaces: `rho watch`'s table is indented too, and a reply
    # containing a line beginning "ask …" would otherwise be
    # indistinguishable from an inbox row.
    def printed_block(lines)
      lines
        .select { |line| line.start_with?(INDENT) }
        .map { |line| line.delete_prefix(INDENT) }
        .join
        .strip
    end

    # `rho result` prints one `status:` line and then the deliverable
    # itself (or one `output:` line saying there is none).
    def read_result(loop_id)
      output, status = @daemon.cli("result", loop_id)
      assert_predicate status, :success?, output
      body = output.lines.drop(1).join.strip
      refute_match(/\Aoutput:\s+\(none/, body, "the loop resolved no deliverable:\n#{output}")
      body
    end

    # PREFIX EQUALITY WITHIN THE BOUND: what was printed has to be the front of what was sealed.
    # Past the follower's own 64 KiB ceiling the preview is a TAIL, so the comparison moves to the
    # last bound bytes.
    def assert_prefix(settled, printed, output)
      normalized = printed.gsub(/\s+/, " ").strip
      body = settled.gsub(/\s+/, " ").strip
      if normalized.bytesize <= TEXT_BOUND
        assert_equal body.byteslice(0, normalized.bytesize), normalized,
          "what the terminal printed is not the front of what the turn sealed:\n#{output}"
      else
        assert_includes body, normalized.byteslice(-TEXT_BOUND, TEXT_BOUND),
          "past the bound the printed text is a tail of the sealed body:\n#{output}"
      end
    end
end
