module E2E
  module Evals
    module Claims
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
