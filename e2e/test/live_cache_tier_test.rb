require "test_helper"
require "json"
require "securerandom"
require "support/live_journey"

# A conversation-hosted invocation carries one-hour cache-control markers. This paid journey checks
# provider counters: the first turn writes a one-hour entry and the next turn reads the shared
# prefix. Unit coverage owns marker placement and pricing arithmetic; this journey observes current
# provider behavior without asserting a monetary total.
#
# THE PREFIX CROSSES THE MINIMUM BY CONSTRUCTION: Sonnet 5 caches
# nothing under 1024 tokens (silently: `cache_creation_input_tokens: 0`),
# so the first task text carries a passage of its own well past it —
# rho's system slots and tool declarations ride ahead of it in the same
# prefix, but the lane does not lean on their size. The 1-hour share is
# not on the public usage shape (the persisted six are), so it is read
# the way settlement reads it, off `provider_usage`, through the operator
# (`usage_receipts!`).
#
# Paid, local, opt-in: E2E_LIVE=1 + ANTHROPIC_API_KEY (the direct lane —
# the account's OpenRouter Anthropic mirrors are 403); under the cost
# stop, its own patience $1. Out of the sweep and the graded lanes.
#   E2E_LIVE=1 rake live_cache_tier
class LiveCacheTierTest < Minitest::Test
  MODEL = ENV.fetch("E2E_CACHE_TIER_MODEL", "anthropic/claude-sonnet-5").freeze
  COST_STOP_USD = 1.0
  # Two facts a tool-less reply can only take from the passage: the
  # colour turn 1 asks for, the animal turn 2 asks for.
  COLOUR = "teal".freeze
  ANIMAL = "heron".freeze
  # ~1.5k tokens of stable text ahead of the tail marker: 120 numbered
  # lines, the two facts planted mid-way.
  PASSAGE_LINES = 120
  TURN_TIMEOUT = 600

  include E2E::LiveJourney

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-cache-tier-e2e")
    @cost_stop_usd = [@cost_stop_usd, COST_STOP_USD].compact.min
  end

  def teardown = finish_live_journey!

  def test_a_conversation_hosted_turn_writes_the_one_hour_tier_and_the_next_turn_reads_it
    connect_and_open_lane!
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    @daemon.control(:post, "/environment", body: { root: project })

    # TURN 1: the passage and a question only it answers; no tool.
    output, status = @daemon.cli("do", turn_1_text, "--model", MODEL, "--dir", project)
    assert_predicate status, :success?, "rho do failed:\n#{output}"
    conversation = output[/^conversation:\s+(\S+)/, 1]
    first_loop = output[/^loop:\s+(\S+)/, 1]
    refute_nil first_loop, "rho do printed no loop id:\n#{output}"
    refute_nil conversation, "rho do printed no conversation id:\n#{output}"
    rho_watch(first_loop, "--timeout", TURN_TIMEOUT.to_s)
    first_row = await_loop_completion(first_loop)
    assert_equal "completed", first_row.fetch("status"), "turn 1 did not settle: #{summarize(first_row)}"
    chat = client.workspace(workspace_public_id).conversations.conversation(conversation)
    first_reply = reply_of(chat)
    refute_nil first_reply, "no reply turn after rho do"
    assert_match(/\b#{COLOUR}\b/i, first_reply.text.to_s, "turn 1 did not read the passage: #{first_reply.text.inspect}")

    # TURN 2: the same prefix plus one question; the provider must READ it.
    said, status = @daemon.cli("say", conversation, turn_2_text, "--mode", "queue")
    assert_predicate status, :success?, "rho say failed:\n#{said}"
    second_reply = await_reply_after(chat, first_reply.position)
    assert_equal "completed", second_reply.status, "turn 2 did not settle: #{second_reply.to_h.inspect}"
    second_loop = second_reply.active_variant.agent_loop_public_id
    refute_nil second_loop, "turn 2 backs no loop: #{second_reply.to_h.inspect}"
    second_row = await_loop_completion(second_loop)
    assert_equal "completed", second_row.fetch("status"), "turn 2's loop did not settle: #{summarize(second_row)}"
    assert_match(/\b#{ANIMAL}\b/i, second_reply.text.to_s, "turn 2 did not read the passage: #{second_reply.text.inspect}")

    # THE RECEIPTS, the way settlement reads them.
    receipts = E2E.operator.usage_receipts!(conversation)
    first = first_receipt_of(receipts, first_loop)
    second = first_receipt_of(receipts, second_loop)
    report(conversation, receipts)

    assert_equal "succeeded", first.fetch("status"), first.inspect
    assert_equal "succeeded", second.fetch("status"), second.inspect
    assert_operator first.fetch("cache_creation_1h_tokens").to_i, :>, 0,
      "THE 1-HOUR TIER on a conversation-hosted turn: turn 1's first round wrote no 1-hour entry — " \
      "the wire's cache_creation breakdown reports #{first.inspect}"
    assert_operator second.fetch("cache_read_tokens").to_i, :>, 0,
      "THE READ: turn 2's first round shares turn 1's prefix and the provider served it nothing from cache — " \
      "#{second.inspect}"
  end

  private

    def client
      @client ||= CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    end

    def reply_of(chat) = chat.turns.list.items.select { |turn| turn.role == "assistant" }.max_by(&:position)

    # The passage: numbered lines of stable prose, the two facts planted
    # where a skimming model still meets them.
    def passage
      @passage ||= (1..PASSAGE_LINES).map do |n|
        case n
        when 41 then "Line #{n}: the lantern by the harbour door was painted #{COLOUR} last spring."
        when 83 then "Line #{n}: a single #{ANIMAL} stood in the shallows every evening that week."
        else "Line #{n}: the tide came in over the flat grey stones and went out again without a sound."
        end
      end.join("\n")
    end

    def turn_1_text
      <<~TEXT.strip
        Read the passage below. Do not use any tool. Then reply with one word only:
        the colour named in the passage.

        #{passage}
      TEXT
    end

    def turn_2_text
      "Without any tool, from the passage above only: reply with one word, the animal it names."
    end

    # The newest assistant turn past `position`, once it is terminal; a
    # failed one fails here with its row, never as a timeout later.
    def await_reply_after(chat, position)
      limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT
      loop do
        newer = chat.turns.list.items.select { |turn| turn.role == "assistant" && turn.position > position }
        failed = newer.find { |turn| turn.status == "failed" }
        flunk "the reply failed: #{failed.to_h.inspect}" if failed
        settled = newer.find { |turn| turn.status == "completed" }
        return settled if settled
        raise Stopped.new("deadline", "turn 2 never settled in #{TURN_TIMEOUT} s") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

        sleep 3
      end
    end

    # A loop's first round is its first receipt in recording order.
    def first_receipt_of(receipts, loop_public_id)
      receipt = receipts.find { |row| row["agent_loop_public_id"] == loop_public_id }
      refute_nil receipt, "no receipt for loop #{loop_public_id}: #{receipts.inspect}"
      receipt
    end

    def report(conversation, receipts)
      puts "\n--- live cache tier ---------------------------------------------"
      puts "model:         #{MODEL}"
      puts "conversation:  #{conversation}"
      receipts.each do |row|
        puts "receipt:       loop=#{row["agent_loop_public_id"]} attempt=#{row["attempt_ordinal"]} " \
             "status=#{row["status"]} input=#{row["input_tokens"].inspect} " \
             "read=#{row["cache_read_tokens"].inspect} write=#{row["cache_creation_tokens"].inspect} " \
             "write_5m=#{row["cache_creation_5m_tokens"].inspect} write_1h=#{row["cache_creation_1h_tokens"].inspect}"
      end
      puts "--------------------------------------------------------------"
    end
end
