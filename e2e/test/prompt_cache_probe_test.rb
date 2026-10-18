$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/manual_anthropic"
require_relative "../../nexus/lib/nexus/prompt_cache/breakpoints"

# THE ONE THING A MOCK CANNOT SEE. Every other cache assertion in the suite is about the shape of
# the request; this one is about whether a real provider READ what the kernel marked, and it drives
# the kernel's own placement module through the real gem to the real API.
#
# THE CLAIM: a tool loop on a THINKING model replays its own reasoning every round, and that is
# exactly the shape the kernel used to skip the rolling tail marker on ("replayed reasoning makes
# the interior volatile"); the vendor's reference says the opposite — prior-turn thinking blocks are
# preserved and the messages cache stays valid inside a tool-use loop. So: three rounds of one turn,
# each round's input the prior round's prefix extended by the model's own answer (thinking blocks
# verbatim, signature and all — the ReplayLadder's native parts — and the call) and the tool's
# result; from round two on `cache_read_input_tokens` ≈ the prior round's whole prompt and the
# uncached share is a sliver, `cache_creation_input_tokens` the delta.
#
# Paid, local, opt-in — over DIRECT api.anthropic.com alone (the account's OpenRouter Anthropic
# mirrors are 403 and cannot stand in): E2E_LIVE=1 ANTHROPIC_API_KEY=… RAILS_ENV=development bundle
# exec rake live_prompt_cache. Skipped, not failed, without both. The offline case beside it
# compiles the same three rounds' bytes and never calls.
class PromptCacheProbeTest < Minitest::Test
  Breakpoints = Nexus::PromptCache::Breakpoints
  # A standalone loop's seconds-apart rounds: the 5-minute tier (the 1-hour tier stays unobserved).
  TIER = "5m".freeze
  ROUNDS = 3
  INSTRUCTIONS = "You look reference items up with the lookup_item tool, exactly one call per turn, " \
                 "and once every item asked for is looked up you answer with their item numbers and nothing else.".freeze
  # One function tool in the gem's flat spelling — the kernel declares its
  # set the same way; the Anthropic wire renders it under `tools`.
  TOOL = {
    type: "function", name: "lookup_item",
    description: "Looks one reference item up by its number and returns its line.",
    parameters: { type: "object", properties: { number: { type: "integer", description: "the item number" } },
                  required: ["number"], additionalProperties: false },
  }.freeze
  ITEMS = [17, 42].freeze
  # A few tokens of prompt may sit outside the markers (the vendor counts
  # the marked prefix to the block boundary); a tenth is the bound.
  SLIVER = 0.1
  MARKER = { "type" => "ephemeral" }.freeze

  def test_a_three_round_tool_loop_reads_the_prior_rounds_prompt_from_round_two_on
    skip "paid, local, opt-in: E2E_LIVE=1 and ANTHROPIC_API_KEY (direct api.anthropic.com)" unless E2E::ManualAnthropic.live?
    E2E::ManualAnthropic.validate!
    salt = "#{Process.pid}-#{Time.now.to_i}"
    client = E2E::ManualAnthropic.client
    model = E2E::ManualAnthropic.model

    input = first_input(salt)
    rounds = []
    ROUNDS.times do
      round = send_round(client, model, input)
      rounds << round
      break if round[:calls].empty?

      input = input + replay(round) + results_of(round, salt)
    end
    puts JSON.generate(model: model, salt: salt, rounds: rounds.map { |round| round[:usage].merge(calls: round[:calls].map { |c| c["name"] }) })

    assert_equal ROUNDS, rounds.size, "the model must call the tool on rounds 1 and 2 (one item each) so round 3 is a continuation " \
                                      "over two replayed answers; it answered without a call: #{rounds.last[:text].inspect}"
    first = rounds.first[:usage]
    assert_operator first[:cache_creation].to_i, :>, 0,
      "round one must WRITE the marked prefix — the system block and the corpus under the tail marker"
    rounds.each_cons(2).with_index(2) do |(prior, this), n|
      prior_prompt = prompt_tokens(prior[:usage])
      this_prompt = prompt_tokens(this[:usage])
      assert_operator this[:usage][:cache_read].to_i, :>=, (prior_prompt * (1 - SLIVER)).floor,
        "round #{n} must READ substantially the prior round's whole prompt (#{prior_prompt} tokens): the tail marker " \
        "was placed under replayed reasoning, so the history — thinking blocks included — is the cached prefix"
      assert_operator this[:usage][:input].to_i, :<, (this_prompt * SLIVER).ceil,
        "round #{n}'s uncached share is a sliver: everything up to the tail marker is read or written"
      assert_operator this[:usage][:cache_creation].to_i, :>, 0,
        "round #{n} WRITES the delta — the prior answer and the tool result — for the round after it"
    end
  end

  # THE THREE ROUNDS' BYTES, WITHOUT A CALL: the kernel's placement through
  # the real gem's compiler to the exact wire payload — two breakpoints a
  # round (the system block's, the last entry's), the tail on the tool
  # result from round two on with the thinking block replayed verbatim
  # before it, and every round's messages the prior round's extended,
  # marker positions aside (the moving tail never rewrites the prefix).
  # A plain constructed request over a placeholder key; nothing is sent.
  def test_the_three_rounds_compile_with_two_breakpoints_each_and_a_prefix_that_only_grows
    client = E2E::ManualAnthropic.client({ "ANTHROPIC_API_KEY" => "offline-placeholder" })
    model = E2E::ManualAnthropic.model({})
    bodies = scripted_inputs("offline").map { |input| compiled_body(client, model, input) }

    assert_equal 3, bodies.size
    bodies.each_with_index do |body, i|
      assert_equal MARKER, body.fetch("system").last["cache_control"], "round #{i + 1}: the stable marker on the system block"
      assert_equal MARKER, body.fetch("messages").last.fetch("content").last["cache_control"], "round #{i + 1}: the tail on the last block"
      assert_equal 2, JSON.generate(body).scan("\"cache_control\"").size, "round #{i + 1}: two breakpoints, no more"
      assert_equal ["lookup_item"], body.fetch("tools").map { |tool| tool["name"] }
      assert_equal "adaptive", body.dig("thinking", "type"), "a thinking model, adaptive mode"
    end
    assert_equal "tool_result", bodies[1].fetch("messages").last.fetch("content").last["type"], "round 2's tail rides the tool result"
    assert_equal %w[thinking text tool_use], bodies[1].fetch("messages")[1].fetch("content").map { |block| block["type"] },
      "the replayed answer: the thinking block verbatim, the text, the call"
    assert_equal "sig-r1", bodies[1].fetch("messages")[1].fetch("content").first["signature"]
    bodies.each_cons(2) do |prior, this|
      stripped = unmarked(prior.fetch("messages"))
      assert_equal stripped, unmarked(this.fetch("messages")).first(stripped.size), "the prior round's messages are this round's prefix"
      assert_equal prior.except("messages"), this.except("messages"), "everything beside the messages is byte-identical across rounds"
    end
  end

  private

    def user_message(text)
      { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }
    end

    def first_input(salt)
      [user_message("#{E2E::ManualAnthropic.corpus(salt)}\nLook up item #{ITEMS.first}, then item #{ITEMS.last}, then answer with both numbers.")]
    end

    # THE KERNEL'S OWN PLACEMENT, not a hand-marked request: the point is
    # to prove the shipped policy, so the probe calls it exactly as
    # ModelRequests::Build does — capable, on the standalone tier.
    def placement_of(input)
      Breakpoints.apply(instructions: INSTRUCTIONS, input: input, capable: true, tier: TIER)
    end

    def request_options(placement)
      { input: placement.input, instructions: placement.instructions, tools: [TOOL], reasoning_effort: "low", max_output_tokens: 2048 }
    end

    def send_round(client, model, input)
      result = client.responses.create(model: model, **request_options(placement_of(input)))
      usage = Hash(result.usage)
      { text: result.output_text.to_s, items: result.output_items, calls: result.tool_calls,
        usage: { input: usage["input_tokens"], cache_read: usage["cache_read_input_tokens"],
                 cache_creation: usage["cache_creation_input_tokens"], output: usage["output_tokens"] } }
    end

    def compiled_body(client, model, input)
      JSON.parse(client.responses.compile(model: model, stream: false, **request_options(placement_of(input))).payload)
    end

    # The vendor's prompt is the three counters together: the uncached
    # share, the cache read, the cache write.
    def prompt_tokens(usage) = usage[:input].to_i + usage[:cache_read].to_i + usage[:cache_creation].to_i

    # THE KERNEL'S REPLAY in the gem's input grammar (`RoundReplay`, the
    # ReplayLadder's `native_parts`): the answer's thinking blocks verbatim
    # — signature and all; a redacted one as its opaque data — then its
    # text, as one assistant entry; each call as a `function_call` item.
    def replay(round)
      parts = round[:items].flat_map do |item|
        case item["type"]
        when "reasoning" then [{ "type" => "thinking", "thinking" => item["text"].to_s, "signature" => item["signature"] }]
        when "redacted_thinking" then [{ "type" => "redacted_thinking", "data" => item["data"] }]
        when "message" then Array(item["content"]).map { |part| { "type" => "text", "text" => part["text"].to_s } }
        else []
        end
      end
      calls = round[:calls].map do |call|
        { "type" => "function_call", "call_id" => call["call_id"], "name" => call["name"], "arguments" => call["arguments"] }
      end
      [{ "role" => "assistant", "content" => parts }] + calls
    end

    # The tool's results, one per call, as `function_call_output` items —
    # the entry the tail marker rides from round two on.
    def results_of(round, salt)
      round[:calls].map do |call|
        number = arguments_of(call)["number"]
        { "type" => "function_call_output", "call_id" => call["call_id"],
          "output" => format("Reference item %04d for run #{salt}: the quick brown fox jumps over the lazy dog and files a report.", number.to_i) }
      end
    end

    # A call's arguments: the wire's JSON text, which the gem always hands back
    # (`AnthropicMessages#tool_use_arguments`) and the scripted rounds write alike.
    def arguments_of(call) = JSON.parse(call["arguments"].to_s)

    # The three rounds' inputs as the live lane builds them, the model's
    # answers scripted: round n's input is round n − 1's plus a replayed
    # answer (a thinking block with its signature, a word, one call) and
    # the tool's result.
    def scripted_inputs(salt)
      answers = ITEMS.each_with_index.map do |number, i|
        items = [{ "type" => "reasoning", "text" => "look item #{number} up", "signature" => "sig-r#{i + 1}" },
                 { "type" => "message", "content" => [{ "type" => "output_text", "text" => "Looking up #{number}." }] }]
        calls = [{ "type" => "function_call", "call_id" => "toolu_r#{i + 1}", "name" => "lookup_item", "arguments" => JSON.generate({ "number" => number }) }]
        { items: items + calls, calls: calls }
      end
      answers.each_with_object([first_input(salt)]) do |answer, inputs|
        inputs << inputs.last + replay(answer) + results_of(answer, salt)
      end
    end

    # The messages with every marker removed: the prefix comparison
    # across rounds, since the tail moves to each round's last block.
    def unmarked(messages)
      messages.map do |message|
        message.merge("content" => message.fetch("content").map { |block| block.except("cache_control") })
      end
    end
end
