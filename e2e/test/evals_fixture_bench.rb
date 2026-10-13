require_relative "../support/evals/bench"
require "minitest/mock"

# Regression policy is independent of the models selected for paid manual evaluations.
module EvalsFixtureBench
  PATH = File.expand_path("../support/fixtures/evals/bench.yml", __dir__)

  def self.read = E2E::Evals::Bench.read(PATH)

  # Some harness entry points default to the on-disk policy. Keep those defaults scoped to the
  # example policy while a test runs, including readers called by another harness component.
  def run
    E2E::Evals::Scorecard.stub(:bench_on_disk, EvalsFixtureBench.read) { super }
  end
end
