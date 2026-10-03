# THE BYTES ONE TREE SENDS, read by that tree's own code under its own bundle — run by the launch
# (`Screen::Bytes`) from the tree's `e2e/` directory:
#
#   bundle exec ruby support/screen/bytes_cli.rb --out DIR --rows ROW --styles nexus,claude \
#     --compose-objectives O1,O7 --task-objectives G0,T5
#
# `--rows` names rows of that tree's compose bench (`ComposeBench::Rows.ids`, the shipped text's row
# first), which differ between trees; the launch passes each arm's registered row. It writes each
# text byte for byte into DIR and prints one `name bytes=N sha256=HEX` line per file: the compose
# bench's `compose` entry per (row, style) as its probe renders it, the task probe's `compose` and
# `task` entries per style as rho declares them, every named objective's prompt (the held-out
# check reads the stimuli from these files), and every named task objective's fixture — the
# project its reads are answered from — as the canonical JSON of its paths and bytes (an objective
# with none reads an empty project, `{}`). Nothing here calls a provider.
$LOAD_PATH.unshift Dir.pwd
require "digest"
require "fileutils"
require "support/compose_bench"
require "support/task_bench"
require_relative "../../../nexus/lib/nexus/canonical_json"

args = ARGV.each_slice(2).to_h { |flag, value| [flag.delete_prefix("--"), value.to_s] }
out = args.fetch("out") { raise ArgumentError, "--out DIR" }
list = ->(name) { args.fetch(name, "").split(",").map(&:strip).reject(&:empty?) }
FileUtils.mkdir_p(out)

write = lambda do |name, text|
  bytes = text.to_s.encode(Encoding::UTF_8)
  File.binwrite(File.join(out, "#{name}.txt"), bytes)
  puts "#{name} bytes=#{bytes.bytesize} sha256=#{Digest::SHA256.hexdigest(bytes)}"
end

list.call("styles").each do |style|
  list.call("rows").each do |row|
    write.call("compose_bench.#{row}.#{style}",
      E2E::ComposeBench::Styles.find(style).definition_for(E2E::ComposeBench::Rows.find(row)).dig("function", "description"))
  end
  declared = E2E::TaskBench::DeclaredSet.function_definitions(style: style)
  { "compose" => "nexus.graph.compose", "task" => "nexus.graph.task" }.each do |name, canonical|
    entry = declared.find { |definition| Nexus::ToolDeclarations.canonical_of(definition) == canonical }
    write.call("task_probe.#{name}.#{style}", entry.dig("function", "description"))
  end
end
list.call("compose-objectives").each { |id| write.call("objective.compose.#{id}", E2E::ComposeBench::Objectives.find(id).text) }
list.call("task-objectives").each do |id|
  objective = E2E::TaskBench::Objectives.find(id)
  write.call("objective.task.#{id}", objective.text)
  write.call("fixture.task.#{id}", Nexus::CanonicalJson.encode(objective.fixture))
end
