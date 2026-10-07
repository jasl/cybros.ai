require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/inflections"
require_relative "claims/namings"

module E2E
  module Evals
    # A REPLY READ AS A CLAIM, FAIL-CLOSED: the answer to "which of these files defines `token`",
    # where `right` is the one file that does and `wrong` maps every other file to the method it
    # defines instead. Naming a file only proves the reply spelled it, so each naming is read in the
    # words around it (`Namings`) and says one of four things: TIED to the token (outright, by a
    # pro-verb such as "does too" or "so does", by the token written before the names, by a later
    # clause that speaks of it — "It also defines `run`." — as a bare answer to the question, or as
    # an item under a heading or lead-in that names the token), NEGATED, tied to its OWN method, or
    # UNREAD; the token written only as what was searched for ("checked … for `run`") ties
    # nothing. A reply FAILS when a wrong file is tied, when it writes a wrong owner with the token
    # (`Alpha.run`, `Alpha::run`, `Alpha#run`) unless a denial comes before it or is its own
    # predicate, or when it never names the right file or only denies it; it PASSES when every
    # wrong naming is negated or tied to its own method, or when the right file is claimed
    # exclusively ("only", "just", "alone") so the other namings carry no claim; anything else is
    # UNREAD — a red saying the reply could not be read, never a silent pass.
    #
    # The same reading answers "which host won the race": `spelling` is every way a reply says the
    # token ("won", "the winner", "responded first"), `fate` what a wrong file is said to have
    # instead, alike for each ("canceled", "slower"), and `exclusive` says the token names ONE file
    # by its nature — a race has one winner — so the reply must TIE the right file to it, and tying
    # it claims it exclusively: a wrong naming the reading leaves unread ("charlie (4s)") carries no
    # claim, while a wrong one tied still fails. A file named as the OBJECT of a comparison ("won
    # over alpha", "ahead of charlie") is neither tied by the token before it, which speaks of the
    # comparison's subject, nor a bare answer: a wrong one is who lost.
    module Claims
      Question = Data.define(:token, :right, :wrong, :spelling, :fate, :exclusive) do
        def initialize(token:, right:, wrong:, spelling: /\b#{Regexp.escape(token)}\b/i, fate: nil, exclusive: false) = super

        def files = [right, *wrong.keys]

        def method_of(file) = wrong.fetch(file, token)

        # What a wrong file is said to have instead of the token: its own method, or the question's
        # one fate for every wrong file.
        def own_pattern(file) = fate || /\b#{Regexp.escape(method_of(file))}\b/

        # A wrong owner written with the token in any Ruby spelling and case: `Alpha.run`,
        # `Alpha::run`, `Alpha#run`, `alpha.run`.
        def owner_pattern
          owners = wrong.keys.map { |file| Regexp.escape(File.basename(file, ".*").camelize) }
          /\b(?:#{owners.join("|")})(?:\.|::|#)#{Regexp.escape(token)}\b/i
        end

        def token_pattern = spelling
      end

      Reading = Data.define(:verdict, :reason) do
        def pass? = verdict == :pass
      end

      NEGATION = /\b(?:not|no|none|neither|nor|never|without|lacks?)\b|n't\b|[❌✗✘]/i
      # "not just", "isn't the only": a denial of exclusivity, which claims MORE files, never fewer.
      NOT_EXCLUSIVE = /(?:\bnot|n't)\s+(?:just|only|alone|the\s+only)\b/i
      EXCLUSIVE = /\b(?:only|just|alone|solely|exclusively)\b/i
      # A pro-verb or a "same for" standing in for the predicate another file was given: "so does",
      # "does too", or a "does" the sentence ends on ("lib/alpha.rb does.", "Two of them do:") —
      # never a verb with its own object ("does something else") or a label ("What it does").
      PRO_VERB = /\b(?:so|as)\s+(?:does|do|did)\b|\b(?:does|do|did)[\s,]+(?:so|too|also|as\s+well|likewise|the\s+same)\b|
                  \b(?:does|do|did)\s*[.!:;]|\bsame\s+(?:for|with|goes|applies)\b|\blikewise\b/ix
      # "…, and lib/alpha.rb too.": the predicate elided altogether.
      ELLIPSIS = /\A\s*(?:(?:and|plus)\s+)?(?:also|too|as\s+well)\s*\z/i
      ASKED = /\b(?:which|whether)\b/i
      # "checked … for `run`", "to find a method named `run`": the token as what was searched for,
      # never what a file says.
      SOUGHT = /\b(?:for|find)\s+(?:(?:a|an|the|any|method|methods|named|called|definition|definitions|of)\s+)*[`*_'"]*(?:def\s+)?(?:self\.)?\z/i
      # A naming with no words around it answers the question itself ("lib/charlie.rb", "Answer:
      # lib/charlie.rb", "Just lib/charlie.rb.").
      BARE = /\A(?:(?:the\s+)?answer(?:\s+is)?|just|only)?\z/i
      # A comparison whose object the naming is — "won over alpha", "beat alpha", "ahead of alpha" —
      # ending the words before it.
      COMPARATIVE = /\b(?:over|against|beat(?:s|ing)?|ahead\s+of|before)[\s`*_'"(]*\z/i
      STRENGTH = %i[tied negated own].freeze

      module_function

      def check(question, reply)
        reading = read(question, reply)
        reading.pass? ? true : reading.reason
      end

      def read(question, reply)
        namings = Namings.new(question).call(reply.to_s)
        right, wrong = namings.partition { |naming| naming.file == question.right }
        said = wrong.map { |naming| [naming, status(question, naming)] }
        tied = said.find { |_naming, kind| kind == :tied }&.first
        spelled = owner_spelled(question, reply.to_s)
        unread = said.find { |_naming, kind| kind == :unread }&.first
        if tied
          fail_with("the reply ties #{tied.file} to `#{question.token}`: #{where(question, tied)}")
        elsif spelled
          fail_with("the reply spells #{spelled}")
        elsif right.empty?
          fail_with("the reply never names #{question.right}")
        elsif right.all? { |naming| status(question, naming) == :negated }
          fail_with("the reply denies that #{question.right} defines `#{question.token}`")
        elsif question.exclusive && right.none? { |naming| status(question, naming) == :tied }
          Reading.new(verdict: :unread, reason: "the reply could not be read as a claim: it never ties #{question.right} " \
                                                "to `#{question.token}`")
        elsif unread && !question.exclusive && right.none? { |naming| exclusive?(naming) }
          Reading.new(verdict: :unread, reason: "the reply could not be read as a claim: #{unread.file} is named with neither its own method, " \
                                                "a denial nor an exclusive claim for #{question.right}: #{where(question, unread)}")
        else
          Reading.new(verdict: :pass, reason: nil)
        end
      end

      def fail_with(reason) = Reading.new(verdict: :fail, reason: reason)

      # The clause the naming came from with any later clause that tied it, and the heading it was
      # read under when that decided it.
      def where(question, naming)
        clause = [naming.clause, *carried(question, naming)].join(" ").strip[0, 160].inspect
        own_status(question, naming) == :unread && naming.scope ? "#{clause} under #{naming.scope.strip[0, 120].inspect}" : clause
      end

      # An unread naming under a heading or lead-in is read by what that heading says.
      def status(question, naming)
        said = own_status(question, naming)
        said == :unread && naming.scope ? scope_status(question, naming.scope) : said
      end

      # The strongest thing any of the naming's predicates says, unless a later clause ties it.
      def own_status(question, naming)
        if carried(question, naming).any?
          :tied
        else
          said = naming.predicates.map { |predicate| predicate_status(question, naming, predicate) }
          STRENGTH.find { |kind| said.include?(kind) } || :unread
        end
      end

      # A later clause read as the naming's can only tie it ("It also defines `run`."), never clear
      # it: a stray "It isn't clear." after a naming is no denial of it.
      def carried(question, naming) = naming.later.select { |text| predicate_status(question, naming, text) == :tied }

      # Words before a file, after the lead's last clause boundary, deny all of it ("Neither …",
      # "`run` is not in …"); words after it deny the token only when the denial comes first ("no
      # `run`", "does not define `run`") — in "defines `run`, not `start`" the denial is of
      # something else. A negation a boundary cuts off from the file ("Not surprisingly, …", "No
      # doubt: …") denies nothing, and a tie behind it is left unread rather than trusted.
      def predicate_status(question, naming, predicate)
        lead = naming.lead.gsub(NOT_EXCLUSIVE, " ")
        near = lead.split(Namings::BOUNDARY, -1).last.to_s
        text = predicate.gsub(NOT_EXCLUSIVE, " ")
        both = "#{lead} #{text}"
        if NEGATION.match?(near) || denies?(question, text)
          :negated
        elsif ASKED.match?(lead) || text.include?("?")
          :unread
        elsif tied_by?(question, naming, lead, text) || (naming.bare && !decided_before?(question, naming) && BARE.match?(words(both)))
          NEGATION.match?(lead) ? :unread : :tied
        elsif both.match?(question.own_pattern(naming.file))
          :own
        else
          :unread
        end
      end

      # Before the token, the denial nearest it governs it only when no clause boundary stands
      # between them: "does not define `start` but defines `run`" denies `start` and still claims
      # `run`.
      def denies?(question, text)
        token = text =~ question.token_pattern
        if token.nil?
          NEGATION.match?(text)
        else
          denial = text[0...token].rindex(NEGATION)
          !denial.nil? && !Namings::BOUNDARY.match?(text[denial...token])
        end
      end

      # A heading that asks ("Defines `run`?") names the question its items answer.
      def scope_status(question, scope)
        text = scope.delete("?").gsub(NOT_EXCLUSIVE, " ")
        if NEGATION.match?(text)
          :negated
        elsif ties?(question, text)
          :tied
        else
          :unread
        end
      end

      def ties?(question, text)
        claims_token?(question, text) || PRO_VERB.match?(text) || ELLIPSIS.match?(words(text))
      end

      # A WRONG file named beside an EXCLUSIVE token is tied by the token itself, before the naming
      # or in its predicate up to the first clause boundary: a race has one winner, so "charlie as
      # well" or "so did alpha" extends another predicate ("finished"), never the win, and a token
      # past a boundary ("alpha first — instead of by who responded first") speaks of something
      # else. The right file is tied as any file is ("bravo — it responded first"): reading its
      # claim loosely can only pass a reply that ties no wrong file.
      def tied_by?(question, naming, lead, predicate)
        said = compared?(question, naming) ? "" : lead
        if question.exclusive && naming.file != question.right
          claims_token?(question, "#{said} #{predicate.split(Namings::BOUNDARY, 2).first}")
        else
          ties?(question, "#{said} #{predicate}")
        end
      end

      # A naming that is the OBJECT of a comparison in an exclusive clause ("bravo won over alpha",
      # "it beat alpha", "ahead of charlie"): the token before it speaks of the comparison's subject,
      # never of the naming.
      def compared?(question, naming) = question.exclusive && COMPARATIVE.match?(naming.before)

      # A naming its clause has already decided, which is never a bare answer: the object of a
      # comparison, or a WRONG file named after the clause tied the right one ("bravo won, alpha and
      # charlie") — a race has one winner, so that naming is who lost.
      def decided_before?(question, naming)
        compared?(question, naming) ||
          (question.exclusive && naming.file != question.right && right_tied_before?(question, naming.before))
      end

      def right_tied_before?(question, before)
        at = before =~ /(?<![\w.-])#{Regexp.escape(question.right)}\b/i
        !at.nil? && claims_token?(question, before[at..])
      end

      # The token written as something said of a file, not only as what was searched for.
      def claims_token?(question, text)
        text.to_enum(:scan, question.token_pattern).any? { !SOUGHT.match?(text[0...Regexp.last_match.begin(0)]) }
      end

      def exclusive?(naming)
        naming.predicates.any? do |predicate|
          text = "#{naming.lead} #{predicate}".gsub(NOT_EXCLUSIVE, " ")
          EXCLUSIVE.match?(text) && !NEGATION.match?(text)
        end
      end

      # `Alpha.run` names a wrong owner with the token even where no file is named. The spelling is
      # denied the way a file is: by a negation before it with no clause boundary between them, or
      # by one in its own predicate, which ends at the first boundary after it.
      def owner_spelled(question, reply)
        Namings.clauses(reply).lazy.flat_map do |clause|
          text = clause.gsub(NOT_EXCLUSIVE, " ")
          text.to_enum(:scan, question.owner_pattern).map { Regexp.last_match }.filter_map do |hit|
            near = text[0...hit.begin(0)].split(Namings::BOUNDARY, -1).last.to_s
            own = text[hit.end(0)..].split(Namings::BOUNDARY).first.to_s
            "#{hit[0]}: #{clause.strip[0, 160].inspect}" unless NEGATION.match?(near) || NEGATION.match?(own)
          end
        end.first
      end

      def words(text) = text.gsub(/[^[:alnum:]\s]/, " ").squish
    end
  end
end

require_relative "claims/race_winner"
