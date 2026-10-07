require_relative "evals/seed"
require_relative "evals/expected"
require_relative "evals/sealed_request"
require_relative "evals/trace"
require_relative "evals/report_line"
require_relative "evals/world_log"
require_relative "evals/agents_on_rails"
require_relative "evals/terminal_bench"
require_relative "evals/docker"
require_relative "evals/drawing"
require_relative "evals/claims"
require_relative "evals/coverage"
require_relative "evals/predicates"
require_relative "evals/corpus"
require_relative "evals/bench"
require_relative "evals/plan"
require_relative "evals/records"
require_relative "evals/scorecard"
require_relative "evals/artifacts"
require_relative "evals/ledger"
require_relative "evals/rescore"
require_relative "evals/member_plane"
require_relative "evals/pump"
require_relative "evals/drivers"

module E2E
  # THE EVALS SUITE: how a MODEL works ON OUR HARNESS — its reach for the platform's capabilities
  # when the situation calls for one, its success when it does, task pass as one dimension among
  # several, efficiency and conduct beside — in rails/ai-evals' FORM (a corpus of tasks, a frozen
  # bench, hidden verification, a dated runs ledger, three runs per model per task), scored from the
  # kernel's trace deterministically. The pieces: `Corpus` (the tasks), `Bench` (the frozen config
  # and its digest), `Plan` (what one invocation runs, grouped by daemon configuration), `Trace`
  # (the kernel's picture, read the gallery's way), `Expected` (reach / success / conduct / facts),
  # `Predicates` (the reads the families share), `Drawing` (the unit tests' vocabulary), `Records`
  # (the jsonl ledger), `Scorecard` (per model, with the three classes), `Ledger` (the trend table),
  # the lane's mixins — `MemberPlane`, `Drivers`, `Pump` — and the riders: `ReportLine` (one line
  # per paid run), `WorldLog` (the world's logs per run), `SealedRequest` (the bytes the last round
  # was sent), `AgentsOnRails` + `TerminalBench` + `Docker` (the two external task-pass yardsticks'
  # loaders and the container hooks they share). The runbook is `docs/evals-runbook.md`.
  module Evals
  end
end
