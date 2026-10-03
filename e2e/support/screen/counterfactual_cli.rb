# THE BUILDER COUNTERFACTUAL IN ONE TREE, read by that tree's own builder under its own bundle — run
# by the launch (`Screen::Counterfactual`) from the tree's `e2e/` directory:
#
#   bundle exec ruby support/screen/counterfactual_cli.rb --corpus declared,bench [--door 1]
#
# It prints one JSON line per stored script of each named corpus (`Screen::Corpus`): whether this
# tree's builder built it, the loud bucket of its refusal, and with `--door 1` the kind the task
# bench's `Door.kind` answers for it as a compose call, or the error it raised. Nothing here calls a
# provider.
$LOAD_PATH.unshift Dir.pwd
require "json"
require "mini_racer"
require "support/screen/counterfactual"

args = ARGV.each_slice(2).to_h { |flag, value| [flag.delete_prefix("--"), value.to_s] }
ids = args.fetch("corpus") { raise ArgumentError, "--corpus ID,…" }.split(",").map(&:strip).reject(&:empty?)
door = nil
if args["door"] == "1"
  require "support/task_bench"
  require "support/task_bench/door"
  door = ->(calls, declared) { E2E::TaskBench::Objectives.door(calls, declared: declared).kind }
end
ids.each { |id| E2E::Screen::Counterfactual.read(id, door: door).each { |row| puts JSON.generate(row) } }
