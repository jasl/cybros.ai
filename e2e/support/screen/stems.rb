require "set"

module E2E
  module Screen
    # THE HELD-OUT CHECK, MECHANICAL: which word stems a stimulus shares with the lines an arm's diff
    # ADDS, so a primary endpoint never measures its own cue. Words are the letter runs of the text,
    # lower-cased, runs under three letters dropped (`C1`, a file's `rb`); a closed stop-list of function
    # words falls away — articles, pronouns, prepositions, conjunctions, auxiliaries, determiners —
    # while the cue-bearing short words (`not`, `one`, `two`, `only`, `per`, `want`) stay; each word
    # is folded by the first step of Porter's stemmer (plurals, `-ed`, `-ing`), with `-ies` read as
    # `-y` so a printed stem stays a word. The same code reads both sides, so a stamp's printed set
    # is exactly what this computes.
    #
    # The registered list holds words, prefixes (`verif*`) and phrases (`one job`): a word matches
    # its stem, a prefix any stem it begins (its trailing `e` dropped, so `judge*` finds `judg`), a
    # phrase its stems in order — and a phrase counts only when both sides carry it whole.
    module Stems
      STOP = %w[
        about above after again against all am an and any are as at be because been before being below between both but by
        can could did do does doing done down during each either else every few for from further had has have having he
        her here hers him his how however if in into is it its itself just may me might mine more most much must my
        neither nor now of off on onto or other our ours out over own same shall she should so some such than that the
        their theirs them themselves then there these they this those though through to too under until up upon us very
        was we were what when where whether which while who whom whose why will with within without would yet you your
        yours yourself
      ].to_set.freeze

      module_function

      # The stems `stimulus` shares with `added_lines` (a String or its lines), and every listed
      # phrase both carry whole.
      def intersection(stimulus, added_lines, list:)
        added = Array(added_lines).join("\n")
        shared = tokens(stimulus).to_set & tokens(added).to_set
        phrases = list.select { |entry| entry.include?(" ") }
          .select { |phrase| carries?(stimulus, phrase) && carries?(added, phrase) }
        shared | phrases.to_set
      end

      # The members of an intersection the registered list names.
      def listed(shared, list:)
        shared.select { |member| list.any? { |entry| names?(entry, member) } }.to_set
      end

      def tokens(text) = words(text).map { |word| stem(word) }.reject { |word| STOP.include?(word) }

      def stem(word)
        step_1b(step_1a(word))
      end

      def words(text) = text.downcase.scan(/[a-z]+/).reject { |word| word.size < 3 || STOP.include?(word) }

      def names?(entry, member)
        if entry.include?(" ")
          entry == member
        elsif entry.end_with?("*")
          member.start_with?(entry.delete_suffix("*").delete_suffix("e"))
        else
          stem(entry) == member
        end
      end

      def carries?(text, phrase)
        wanted = phrase.split.map { |word| stem(word) }
        text.downcase.scan(/[a-z]+/).map { |word| stem(word) }.each_cons(wanted.size).include?(wanted)
      end

      # Plurals: `-sses` → `-ss`, `-ies` → `-y`, a lone `-s` dropped unless the word ends `ss`,
      # `us` or `is`.
      def step_1a(word)
        if word.end_with?("sses") then word.delete_suffix("es")
        elsif word.end_with?("ies") && word.size > 4 then "#{word.delete_suffix("ies")}y"
        elsif word.end_with?("s") && !word.end_with?("ss", "us", "is") && word.size > 3 then word.delete_suffix("s")
        else word
        end
      end

      # `-eed` → `-ee` over a measure above zero; `-ed`/`-ing` dropped where the rest holds a vowel,
      # then `at`/`bl`/`iz` regain their `e`, a doubled consonant (not l, s, z) is single, and a
      # one-measure consonant-vowel-consonant ending regains its `e` (`named` → `name`).
      def step_1b(word)
        if word.end_with?("eed")
          measure(word.delete_suffix("eed")).positive? ? word.delete_suffix("d") : word
        else
          suffix = %w[ed ing].find { |ending| word.end_with?(ending) && vowel?(word.delete_suffix(ending)) }
          suffix ? restore(word.delete_suffix(suffix)) : word
        end
      end

      def restore(stem)
        if stem.end_with?("at", "bl", "iz") then "#{stem}e"
        elsif stem.match?(/([^aeiouylsz])\1\z/) then stem.chop
        elsif measure(stem) == 1 && cvc?(stem) then "#{stem}e"
        else stem
        end
      end

      def vowel?(stem) = (0...stem.size).any? { |index| vowel_at?(stem, index) }

      # Porter's m: how many vowel-then-consonant runs the stem holds.
      def measure(stem)
        (0...stem.size).map { |index| vowel_at?(stem, index) ? "v" : "c" }.join.squeeze.scan("vc").size
      end

      def cvc?(stem)
        stem.size >= 3 && !vowel_at?(stem, stem.size - 3) && vowel_at?(stem, stem.size - 2) &&
          !vowel_at?(stem, stem.size - 1) && !"wxy".include?(stem[-1])
      end

      # `y` is a vowel after a consonant.
      def vowel_at?(stem, index)
        "aeiou".include?(stem[index]) || (stem[index] == "y" && index.positive? && !vowel_at?(stem, index - 1))
      end
      private_class_method :words, :names?, :carries?, :step_1a, :step_1b, :restore, :vowel?, :measure, :cvc?, :vowel_at?
    end
  end
end
