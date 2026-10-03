module E2E
  module Evals
    module Claims
      # "WHICH HOST WON THE RACE?" — the question compose-race and compose-race-anon read their
      # replies with: bravo answers first (`bin/probe` sleeps alpha 6 s, bravo 2 s, charlie 4 s). A
      # reply fails when it ties alpha or charlie to winning, and cannot be read when it never ties
      # bravo to it; a race has one winner, so tying bravo claims it alone and a loser named with
      # its fate ("canceled", "slower"), its timing ("charlie (4s)") or as what bravo beat ("bravo
      # won over alpha") carries no claim. Winning is said many ways: won, beat, the fastest, the
      # first host to respond, finished or came back first. A probe's command line names its host
      # as what was probed, never as a claim, so `bin/probe alpha` reads as `bin/probe` alone.
      module RaceWinner
        QUESTION = Question.new(
          token: "won", right: "bravo", wrong: { "alpha" => "lost", "charlie" => "lost" },
          spelling: /\b(?:won|wins?|winner|winning|beats?|fastest|quickest|
                      first\s+(?:\w+\s+){0,2}?to\s+(?:respond|answer|reply|return|finish)|
                      (?:finished|came\s+back|completed|responded|answered|replied|returned)\s+first)\b/ix,
          fate: /\b(?:lost|los(?:es|er|ers)|slower|cancel(?:l)?ed|dropped|abandoned|stopped|discarded)\b/i,
          exclusive: true
        )
        PROBED = %r{bin/probe\s+(?:alpha|bravo|charlie)\b}i

        module_function

        def check(reply) = Claims.check(QUESTION, reply.to_s.gsub(PROBED, "bin/probe"))

        def read(reply) = Claims.read(QUESTION, reply.to_s.gsub(PROBED, "bin/probe"))
      end
    end
  end
end
