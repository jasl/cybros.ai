module AgentRuns
  # THE WORDS A READING MODEL GETS for a step a provider declined — or was
  # overloaded for on every attempt of its budget: the
  # failed task's `error_detail`, which every envelope renders after the
  # `model_refused` key and before its own next-step line
  # (`TaskResultEnvelope::DECLINED`). Its reader is a model deciding its
  # next move, so it names who declined, the provider's category, that the
  # step failed with no output, and why nothing re-ran it — never the
  # provider's own explanation, which is written for people and stays on
  # the round's narration and the invocation.
  #
  #   anthropic/claude-opus-5-5 declined this step (cyber), so it failed with
  #   no output; @rho declares no fallback model, so nothing re-ran it
  #
  # The category is the provider's word verbatim, with the gem's meaning
  # beside a word that does not say it plainly (`reasoning_extraction: the
  # request asks for the model's own reasoning`); a null category drops the
  # parenthesis, so no word is invented. The verdict's stand is the case
  # that ended the step where it stood, each told as what it means to the
  # reader — a fallback that was never declared, one that is the declining
  # model itself, one that cannot take the request, and a step already
  # re-run once are four different facts.
  #
  # The detail holds 256 characters (`FailNode` cuts there). A sentence
  # whose meaning would not fit keeps the bare word, and one that still
  # would not ends at a word, so a reader never gets a word cut in half.
  module RefusalSentence
    LIMIT = 256

    module_function

    # `declaring_profile` is the loop's one declaring-profile rule: the
    # agent answering it, or nil when a person does and declares nothing.
    def for(invocation:, verdict:, declaring_profile:)
      glossed = sentence(invocation, verdict, declaring_profile, gloss: true)
      return glossed if glossed.length <= LIMIT

      bare = sentence(invocation, verdict, declaring_profile, gloss: false)
      bare.length <= LIMIT ? bare : bare.first(LIMIT + 1).sub(/[\s,;]+\S*\z/, "").sub(/[,;]+\z/, "")
    end

    def sentence(invocation, verdict, declaring_profile, gloss:)
      "#{declined_by(invocation)} #{cause(invocation, gloss)}, " \
        "so it failed with no output; #{tail(invocation, verdict, declaring_profile, gloss)}"
    end

    # What the model did to the step, by its own verb: a classifier's word
    # with its category, or the provider's overload on every attempt.
    def cause(invocation, gloss)
      return "was overloaded on every attempt of this step" if invocation.overloaded?

      verb = invocation.blocked? ? "blocked" : "declined"
      "#{verb} this step#{category(invocation, gloss)}"
    end

    def tail(invocation, verdict, declaring_profile, gloss)
      case verdict.stand
      when :no_fallback
        if declaring_profile
          "@#{declaring_profile.handle} declares no fallback model, so nothing re-ran it"
        else
          "no fallback model is declared for it, so nothing re-ran it"
        end
      when :fallback_is_current
        "the declared fallback model is the one that #{invocation.overloaded? ? "was overloaded" : "declined it"}, " \
          "so nothing re-ran it"
      when :fallback_unavailable
        "the declared fallback model #{verdict.fallback} cannot take this request (#{verdict.word}), " \
          "so nothing re-ran it"
      when :already_switched
        "it was already re-run once after #{declined_by(verdict.earlier)} #{earlier_cause(verdict.earlier, gloss)}, " \
          "so nothing re-ran it again"
      when :blocked then "blocked content is never sent to another model"
      when :abandoned then "nothing waits for it any more, so nothing re-ran it"
      else raise ArgumentError, "unknown refusal stand: #{verdict.stand.inspect}"
      end
    end

    # A spawned child's DIRECT reply a provider declined, as its parent
    # reads it — on the delegation, the `wait` tool and the relayed reply
    # alike: who declined it and the category, then the envelope's
    # next-step line. No step to name, no fallback case to tell: a reply
    # the answerer's fallback re-asked is read from that sample instead.
    def for_reply(invocation)
      verb = invocation.blocked? ? "blocked" : "declined"
      "(the reply ended failed: #{declined_by(invocation)} #{verb} it#{category(invocation, true)}, " \
        "so it has no text)\n#{TaskResultEnvelope::DECLINED}"
    end

    # The earlier switch cause, told by its own verb.
    def earlier_cause(invocation, gloss)
      return "was overloaded" if invocation.overloaded?

      "declined it#{category(invocation, gloss)}"
    end

    def declined_by(invocation) = "#{invocation.provider_id}/#{invocation.model_ref}"

    def category(invocation, gloss)
      word = invocation.refusal_category
      return if word.blank?

      meaning = SimpleInference::Responses::Refusal::MEANINGS[word] if gloss
      meaning ? " (#{word}: #{meaning})" : " (#{word})"
    end
  end
end
