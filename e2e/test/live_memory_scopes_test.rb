require "test_helper"
require "securerandom"
require "support/live_journey"

# MEMORY ACROSS WORKSPACES, ON A REAL MODEL. `live_conversation` proves `workspace/` across two
# turns in ONE workspace, through rho; this proves the `user/` rung's whole reach: a note a real
# model saves through rho's turn — under the person rho answers to — is read by a member-plane
# conversation in a SECOND workspace of the same person, a `direct_reply` no loop backs, whose only
# reader of memory is the assembly block. The person's own door confirms where the note landed
# before the second workspace is asked, so a model that saved it under the wrong scope fails legibly
# here rather than as a blank answer there.
#
# Paid, local, opt-in: E2E_LIVE=1.
class LiveMemoryScopesTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  # ONE hyphen-free token. The first paid run answered `d55ed588` to a
  # note reading `remember-d55ed588`: the model read "the word" as the
  # part after the hyphen, and the whole-string assertion failed on a turn
  # that HAD carried the note across workspaces. A token nothing splits is
  # what the reply is asked to repeat.
  REMEMBERED = "zq#{SecureRandom.hex(4)}".freeze
  # One model call with no tools; a paid reply settles in seconds, and a
  # stall must fail here with the logs dumped.
  TURN_TIMEOUT = 300
  TURN_POLL = 3

  include E2E::LiveJourney

  def setup = start_live_journey!(MODEL, home_prefix: "rho-live-memory-scopes-e2e")
  def teardown = finish_live_journey!

  def test_a_note_saved_through_rho_is_read_by_a_conversation_in_another_workspace
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    # TURN 1, through `rho do` in rho's dedicated workspace: the model
    # saves the word under `user/` — the scope of the person this turn
    # answers to, rho's steward.
    output, status = @daemon.cli("do",
      "Using the memory tools, save a note at user/token.md whose whole content is " \
      "the word #{REMEMBERED}. Reply DONE.",
      "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    loop_id = output[/^loop:\s+(\S+)/, 1]
    refute_nil loop_id, output

    watched, status = rho_watch(loop_id, "--timeout", "600")
    assert_predicate status, :success?, watched
    assert_match(/^status:\s+completed$/, watched, watched)
    row = await_loop_completion(loop_id)
    assert_equal "completed", row.fetch("status"), summarize(row)

    # WHERE IT LANDED, read as the person through their own door.
    steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    paths = steward_client.profile.memory.list.map(&:path)
    assert_includes paths, "user/token.md",
      "the model did not save the note under user/ (the person's door lists #{paths.inspect}): #{summarize(row)}"
    saved = steward_client.profile.memory.read("user/token.md")
    assert_includes saved.content, REMEMBERED, "the note's content is not the word: #{saved.content.inspect}"

    # TURN 2, on the member plane in a SECOND workspace of the same person:
    # a conversation no loop backs, whose reply is assembled with the block
    # and nothing else — the note crossed workspaces on the person alone.
    other = steward_client.workspaces.create(
      name: "Memory scopes live #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    conversations = steward_client.workspace(other.public_id).conversations
    chat = conversations.conversation(
      conversations.create(title: "The other workspace", idempotency_key: SecureRandom.uuid).public_id
    )
    chat.inputs.create(
      kind: "direct_reply", model: MODEL,
      text: "What word did I ask you to remember? Answer with the word only.",
      idempotency_key: SecureRandom.uuid
    )
    reply = await_reply(chat)
    assert_equal "completed", reply.status, reply.to_h.inspect
    assert_includes reply.text.to_s, REMEMBERED,
      "the reply in the other workspace did not carry the remembered word: #{reply.text.inspect}"
    report(row, other.public_id, reply)
  end

  private

    # The first `direct_reply` that settles on the timeline; a failed one
    # is a failure HERE, with its row, never a timeout later.
    def await_reply(chat)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        reply = chat.turns.list.items.find { |turn| turn.kind == "direct_reply" }
        return reply if reply && %w[completed failed].include?(reply.status)
        raise "the reply never settled in the other workspace" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep TURN_POLL
      end
    end

    def report(row, workspace, reply)
      tools = row.fetch("tasks").select { |t| t.fetch("kind") == "tool_task" }
      puts "\n--- live memory scopes ----------------------------------------"
      puts "model:      #{MODEL}"
      puts "turn 1:     #{summarize(row)}"
      puts "calls:      #{tools.map { |t| t["tool_name"] }.tally.map { |n, c| "#{n}x#{c}" }.join(" ")}"
      puts "workspace:  #{workspace} (the second)"
      puts "reply:      #{reply.text.to_s.strip[0, 120].inspect}"
      puts "--------------------------------------------------------------"
    end
end
