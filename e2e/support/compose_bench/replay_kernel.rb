# THE KERNEL HALF OF `Replay`, run by `bin/rails runner` inside one tree's Nexus: it reads a JSON
# document on stdin — `root` (the tree), `scripts` (`[{script, params}]`), `tool_names` and
# `declarations` (the round's tool set and its function entries) — and writes one JSON line per
# script: whether the evaluator built it, and the graph each lowering placed, neutral enough for the
# harness to compare. `shape` is the tree's own harness lowering (`Shape.lower`, and the refusals it
# reads the kernel's lowering making, `Shape.lowering_refusal`); `kernel` is the tree's own
# `Compose::Lower` in its stage form — the call's namespace and the round's inherited surface are
# the same on every script — then `Tasks::Compile`, from a tip shaped as `KernelTool.branch_tip`
# shapes a compose call's: no spine, the branch mark, detached as a call without `wait` is, waiting
# on the call. A stage is its own node on both sides: the replay stops at the first expansion
# boundary. Nothing here opens a database connection; the compile is a pure function of its steps.
require "json"

input = JSON.parse($stdin.read)
root = input.fetch("root")
tool_names = input.fetch("tool_names")

# The kernel's own constants load first, through the autoloader, so the harness file's relative
# requires of the same library files find them loaded.
evaluator = Nexus::Compose::Evaluator
compile = AgentLoops::Tasks::Compile
lower = AgentLoops::Compose::Lower
require File.join(root, "e2e/support/compose_bench/shape")
shape = E2E::ComposeBench::Shape

call = "compose-call"
caller = Data.define(:authored_by, :lifetime, :wake).new(authored_by: "model", lifetime: "conversation", wake: "auto")
defaults = { "model" => { "model" => "replay/model" }, "tools" => input.fetch("declarations") }
tip = AgentLoops::Tasks::Tip.new(
  spine: nil, waits: [AgentLoops::Tasks::Known.new(key: call, kind: "tool_task", mark: nil)], reads: [],
  mark: compile::BRANCH, detached: true, lifetime: "conversation", wake: "auto"
)

neutral_shape = lambda do |graph|
  { "nodes" => graph.nodes.map { |node| { "key" => node.key, "kind" => node.kind, "race" => node.race, "reads" => node.reads } },
    "edges" => graph.edges }
end

neutral_kernel = lambda do |compiled|
  { "nodes" => compiled.nodes.map do |node|
      { "key" => node.fetch("node_key"), "task_kind" => node.fetch("type").demodulize.underscore,
        "race" => (node["join_mode"] == "any" ? "any" : node["quorum_k"]),
        "input_from" => Array(node["input_from_node_keys"]), "result_from" => Array(node["result_from_node_keys"]) }
    end,
    "edges" => compiled.edges.map { |edge| [edge.fetch("from_key"), edge.fetch("to_key")] }.reject { |from, _| from == call } }
end

input.fetch("scripts").each do |entry|
  built = evaluator.call(script: entry.fetch("script").to_s, params: entry["params"] || {}, tool_names: tool_names)
  unless built.built?
    puts JSON.generate({ "built" => false, "refusal" => built.refusal.to_s })
    next
  end

  refused = shape.lowering_refusal(built.steps, tool_names)
  harness = refused ? { "refusal" => refused.refusal } : neutral_shape.(shape.lower(built.steps))
  lowered = lower.stage(built: built, node: caller, model_defaults: defaults)
  kernel =
    if !lowered.lowered?
      { "refusal" => lowered.refusal.to_s }
    else
      compiled = compile.call(lowered.steps, tip, kernel: true)
      compiled.valid? ? neutral_kernel.(compiled) : { "refusal" => compiled.errors.map { |error| error["code"] }.join(", ") }
    end
  puts JSON.generate({ "built" => true, "shape" => harness, "kernel" => kernel })
end
