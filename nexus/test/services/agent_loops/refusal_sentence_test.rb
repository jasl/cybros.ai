require "test_helper"

# THE DETAIL HOLDS 256 CHARACTERS, and a reading model never gets a word cut
# in half. Built from a long synthetic ref (as the declining model and as
# the fallback), the longest category word the
# gem types, the longest handle a profile can carry and the resolver's
# longest word: every stand fits whole where it can, keeps the bare word
# where the meaning would not fit, and ends on a whole word where even that
# would not.
class AgentLoops::RefusalSentenceTest < ActiveSupport::TestCase
  STANDS = %i[no_fallback fallback_is_current fallback_unavailable already_switched blocked abandoned].freeze
  LONGEST_RESOLVER_WORD = "unsupported_generation_parameter".freeze
  LONG_MODEL_REF = "dev/vendor/research-model-with-a-long-release-name".freeze

  test "a sentence with the longest ordinary words fits whole, its meaning beside the opaque word" do
    %w[cyber reasoning_extraction].each do |category|
      STANDS.each do |stand|
        sentence = sentence_for(stand, ref: "dev/primary", category: category)
        assert_operator sentence.length, :<=, AgentLoops::RefusalSentence::LIMIT, "#{stand} with #{category}"
        assert_match(/(re-ran it|re-ran it again|another model)\z/, sentence, "#{stand} with #{category} stands whole")
      end
    end
    assert_includes sentence_for(:no_fallback, ref: "dev/primary", category: "reasoning_extraction"),
      "(reasoning_extraction: the request asks for the model's own reasoning)"
  end

  test "a long ref, category and handle never pass the detail or cut a word" do
    ref = LONG_MODEL_REF
    words = SimpleInference::FinishQuality::GEMINI.keys.map { |key| key.delete_prefix("PROMPT_") } +
      SimpleInference::Responses::Refusal::MEANINGS.keys
    words.uniq.each do |category|
      STANDS.each do |stand|
        sentence = sentence_for(stand, ref: ref, category: category)
        assert_operator sentence.length, :<=, AgentLoops::RefusalSentence::LIMIT, "#{stand} with #{category}"
        assert_includes full_words(stand, ref, category), sentence.split.last.delete_suffix(",").delete_suffix(";"),
          "#{stand} with #{category} ends on a whole word"
      end
    end
    assert_match(/declared fallback model #{Regexp.escape(ref)} cannot take/,
      sentence_for(:fallback_unavailable, ref: ref, category: "SAFETY"), "a long fallback keeps its name")
  end

  private

    def sentence_for(stand, ref:, category:)
      provider_id, model_ref = ref.split("/", 2)
      invocation = ModelInvocation.new(provider_id: provider_id, model_ref: model_ref,
        refusal_category: category, finish_quality: stand == :blocked ? "blocked" : "refused")
      verdict = AgentLoops::ModelFallback::Verdict.new(stand: stand, fallback: ref, word: LONGEST_RESOLVER_WORD,
        earlier: invocation)
      AgentLoops::RefusalSentence.for(invocation: invocation, verdict: verdict,
        declaring_profile: User.new(handle: "a" * 32))
    end

    def full_words(stand, ref, category)
      provider_id, model_ref = ref.split("/", 2)
      invocation = ModelInvocation.new(provider_id: provider_id, model_ref: model_ref,
        refusal_category: category, finish_quality: stand == :blocked ? "blocked" : "refused")
      verdict = AgentLoops::ModelFallback::Verdict.new(stand: stand, fallback: ref, word: LONGEST_RESOLVER_WORD,
        earlier: invocation)
      AgentLoops::RefusalSentence.sentence(invocation, verdict, User.new(handle: "a" * 32), gloss: false)
        .split.map { |word| word.delete_suffix(",").delete_suffix(";") }
    end
end
