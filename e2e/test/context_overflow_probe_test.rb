$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/manual_anthropic"
require "support/manual_openrouter"

# THE ONE CLAIM IN THE CLASSIFIER THAT IS ABOUT SOMEBODY ELSE'S SERVER.
#
# The third compaction arm reads a provider's own length rejection, and
# on the four lanes that declare no token counter that refusal is the
# ONLY signal a round is too big — there is no pre-send window gate to
# catch it first. Every other test of that arm is offline and therefore
# circular: it asserts that a pattern I wrote matches a body I also
# wrote. This one sends a request that cannot fit to the live lane this
# repo actually runs, and asks whether the phrase the kernel watches for
# is the phrase the provider really says.
#
# It also records the answer nobody expected, which is that OpenRouter
# has TWO behaviours here and only one of them is a refusal. See
# `test_some_endpoints_silently_truncate` below.
#
# CHEAP BY CONSTRUCTION: a refused request generates no tokens. The
# truncating case does bill, at roughly a tenth of a cent.
#
# Paid, local, opt-in: E2E_LIVE=1 RAILS_ENV=development.
class ContextOverflowProbeTest < Minitest::Test
  # An endpoint that REFUSES: a 16,384-token window, and not a
  # first-party mirror this account is unlicensed for.
  REFUSING_MODEL = "microsoft/phi-4".freeze

  # An endpoint that does NOT refuse, kept as a named fact rather than a
  # footnote. Both were observed in the same run.
  TRUNCATING_MODEL = "gryphe/mythomax-l2-13b".freeze

  # ~45,000 tokens: past the refusing endpoint's window by nearly three
  # times, so no plausible tokenizer disagreement can make it fit.
  OVERSIZED = ("the quick brown fox files a report. " * 5_000).freeze

  def test_the_live_lane_says_what_the_kernel_watches_for
    E2E::ManualOpenRouter.validate!

    error = assert_raises(SimpleInference::HTTPError) { send_oversized(REFUSING_MODEL) }
    detail = detail_for(error)
    puts JSON.generate(model: REFUSING_MODEL, status: error.status, detail: detail)

    assert_includes overflow_statuses, error.status,
      "the status gate is deliberately narrow — a length rejection outside " \
      "it is invisible to the arm"
    assert_empty exclusions.select { |pattern| pattern.match?(detail) },
      "an exclusion matched a genuine length rejection, and the exclusions " \
      "run first and win — the arm would be unreachable on this lane"
    assert patterns.any? { |pattern| pattern.match?(detail) },
      "NO SHIPPED PATTERN MATCHES THE LIVE REFUSAL:\n#{detail}\n" \
      "the arm is dead on this lane and the round burns its retry budget " \
      "re-sending a request that will never fit"
  end

  # THE THING A MOCK COULD NEVER HAVE TOLD US, and the reason this probe
  # was worth its cost. Some OpenRouter endpoints do not refuse an
  # oversized request at all: they answer 200 having silently discarded
  # most of the input. 180,000 characters go out, ~2,250 prompt tokens
  # come back billed, and the reply is a confident answer written from a
  # fraction of the context the caller sent.
  #
  # That is strictly worse than a refusal. A refusal is honest and
  # repairable — it is exactly what the third arm turns into a
  # compaction. Silent truncation is neither: the kernel cannot see it in
  # the result, the model answers as if nothing happened, and somebody
  # else's truncation policy has quietly replaced the kernel's own
  # compaction.
  #
  # `transforms: []` — OpenRouter's documented opt-out from middle-out
  # compression — was sent and changed nothing: identical token counts to
  # the digit, with and without it.
  #
  # This test PINS the behaviour rather than asserting it is acceptable.
  # It is recorded as an open ledger item, not fixed here.
  def test_some_endpoints_silently_truncate
    E2E::ManualOpenRouter.validate!

    result = send_oversized(TRUNCATING_MODEL)
    usage = Hash.try_convert(result.usage) || {}
    counted = usage["prompt_tokens"].to_i
    puts JSON.generate(model: TRUNCATING_MODEL, sent_bytes: OVERSIZED.bytesize,
      prompt_tokens: counted)

    assert_operator counted, :>, 0, "the request was billed, so it was served"
    assert_operator counted, :<, 10_000,
      "if this endpoint has started REFUSING or honouring the full input, the " \
      "silent-truncation hazard is gone and the ledger item can be closed"
  end

  private

    def send_oversized(model)
      E2E::ManualOpenRouter.client(model).responses.create(
        model: model, max_output_tokens: 8,
        # OpenRouter's documented opt-out from middle-out compression.
        # Sent so the observation is of the provider's floor behaviour,
        # not of a default we failed to turn off.
        extra_body: { "transforms" => [] },
        input: [{ "role" => "user",
                  "content" => [{ "type" => "input_text", "text" => OVERSIZED }] }]
      )
    end

    # The KERNEL's own constants, read from its source rather than
    # restated here — a probe that retypes the patterns proves only that
    # I can retype them.
    def apply_result_source
      @apply_result_source ||= File.read(File.expand_path(
        "../../nexus/app/services/model_invocations/apply_result.rb", __dir__
      ), encoding: "UTF-8")
    end

    def constant_body(name)
      apply_result_source[/#{name} = \[(.*?)\]\.freeze/m, 1] ||
        raise("#{name} not found in apply_result.rb")
    end

    def patterns
      constant_body("OVERFLOW_PATTERNS").scan(%r{/(.*?)/i})
        .map { |(source)| Regexp.new(source, Regexp::IGNORECASE) }
    end

    def exclusions
      constant_body("OVERFLOW_EXCLUSIONS").scan(%r{/(.*?)/i,})
        .map { |(source)| Regexp.new(source, Regexp::IGNORECASE) }
    end

    def overflow_statuses
      constant_body("OVERFLOW_STATUSES").split(",").map { |value| Integer(value.strip) }
    end

    # The same fields the kernel reads, in the same order — structured
    # only, never the raw body.
    def detail_for(error)
      body = Hash.try_convert(error.body) || {}
      inner = Hash.try_convert(body["error"]) || {}
      [inner["message"], inner["code"], inner["type"], error.message].compact.join(" ")
    end
end
