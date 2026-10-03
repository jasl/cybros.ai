# THE REHEARSAL'S CLAUSES: the protocol every screen's `clauses.rb` answers (`E2E::Screen::Analysis`),
# read over the fake transport's draws. Both arms read the same row and every answer is canned, so the
# one clause reads the engine and never a model: each arm's compose draws reach their compose call
# alike. The verdict is REHEARSAL whatever the clause reads — a rehearsal lands nothing.
extend self

def kernel_finding(_draws) = []

def clauses(draws)
  reached = ->(draw) { draw["reached"] == true }
  [E2E::Screen::Clause.contrast(name: "R0", arm: "candidate", against: "base", test: reached, rule: "Δ = 0 on a self-pair",
    arm_draws: E2E::Screen::Records.select(draws, arm: "candidate", instrument: "compose"),
    base_draws: E2E::Screen::Records.select(draws, arm: "base", instrument: "compose")) { |clause| clause.contrast.diff.zero? }]
end

def verdict(clauses)
  E2E::Screen::Analysis::Verdict.new(name: "REHEARSAL",
    text: "The engine ran end to end over the fake transport; R0 #{clauses.all?(&:holds) ? "holds" : "does not hold"}. Nothing lands.")
end

def reads(draws)
  %w[base candidate].map do |arm|
    tasks = E2E::Screen::Records.select(draws, arm: arm, instrument: "task")
    "#{arm}: #{tasks.count { |draw| draw["pass"] == true }}/#{tasks.size} task draws pass on the canned answer"
  end
end

def figures(_draws, _jobs) = []

def stops(_figures) = []
