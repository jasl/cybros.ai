# THE DOOR READER IN ONE TREE, kinded by that tree's own task bench under its own bundle — run by the
# launch (`Screen::DoorReader`) from the with tree's `e2e/` directory:
#
#   bundle exec ruby support/screen/door_reader_cli.rb
#
# It prints one JSON object: every tracked door record (`Screen::Corpus.door_records`) labelled by
# the registered look rule and the task bench's `Door.kind`, tallied per (bench, task, model)
# (`Screen::DoorReader.tally`). Nothing here calls a provider.
$LOAD_PATH.unshift Dir.pwd
require "json"
require "mini_racer"
require "support/task_bench"
require "support/task_bench/door"
require "support/screen/door_reader"

door = ->(calls, declared) { E2E::TaskBench::Objectives.door(calls, declared: declared) }
reader = E2E::Screen::DoorReader
puts JSON.generate(reader.tally(E2E::Screen::Corpus.door_records, door: door, declared: reader.declared))
