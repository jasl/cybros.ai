# THE KERNEL HALF OF `Delivery`, run by `bin/rails runner` inside one tree's Nexus on that tree's own
# test database (the caller names it): it reads a JSON document on stdin — `scripts`
# (`[{script, params}]`), `tool_names` and `declarations` — and writes one JSON line per script with
# what the kernel's rows say comes back to the caller for the plan the script builds, both ways a
# compose call places it: WAITED, under a head the envelope splices under (`Delivery.compiled`, the
# head's added reads), and DETACHED, from a branch tip of its own with every row settled in
# placement order (`Delivery.settled` over the wake's sinks, before a race is expanded to its
# selection, and `WakeContinuation.undelivered`, after), and the kernel's bound on what one head
# may read (`KERNEL_MAX_INPUT_FROM`). Each script's two loops are appended,
# settled and read inside one transaction the runner rolls back, over the suites' own fixtures
# loaded inside it, so the database is left as it was found. A stage is one node: nothing expands.
require "json"

input = JSON.parse($stdin.read)
tool_names = input.fetch("tool_names")
evaluator = Nexus::Compose::Evaluator
lower = AgentLoops::Compose::Lower
tasks = AgentLoops::Tasks
caller = Data.define(:authored_by, :lifetime, :wake).new(authored_by: "model", lifetime: "conversation", wake: "auto")
defaults = { "model" => { "model" => "dev/mock-text" }, "tools" => input.fetch("declarations") }
fixtures = Rails.root.join("test/fixtures").to_s

# A loop whose spine round `r1` has answered, as the wake and a waited head find it.
answered_loop = lambda do
  workspace = Workspace.find(ActiveRecord::FixtureSet.identify(:shared))
  created = AgentLoops::Create.call(AgentLoops::Create::Command.new(
    workspace: workspace, creating_user: User.find(ActiveRecord::FixtureSet.identify(:member)),
    steps: [{ "model" => { "key" => "r1", "model" => { "model" => "dev/mock-text" }, "prompt" => "p" } }],
    billing_subject: nil, idempotency_key: nil, approval_mode: "bypass"
  ))
  raise "the loop was refused: #{created.outcome} #{created.errors.inspect}" unless created.created?

  loop_row = created.agent_loop
  loop_row.agent_loop_nodes.where(node_key: "r1").update_all(status: "completed", completed_at: Time.current)
  loop_row.update!(status: "running")
  loop_row
end

append = lambda do |loop_row, steps, tip, **command|
  result = tasks::Append.call(tasks::Append::Command.kernel(agent_loop: loop_row, steps: steps, tip: tip, origin: "model",
    **command))
  raise "the kernel refused the plan: #{result.outcome} #{result.errors.inspect}" unless result.applied?
end

# Every row settled in placement order, as its sources settle: a race ends on its first exit and
# cancels its losers, which are then terminal and left as they are.
settle_all = lambda do |loop_row|
  loop_row.agent_loop_nodes.where.not(node_key: "r1").order(:id).pluck(:id).each do |id|
    node = AgentLoopNode.find(id)
    next if node.terminal? || node.join_mode.present?

    AgentLoopNode.where(id: id).update_all(status: "completed", completed_at: Time.current)
    AgentLoops::Release.settled(node.reload)
  end
end

input.fetch("scripts").each do |entry|
  built = evaluator.call(script: entry.fetch("script").to_s, params: entry["params"] || {}, tool_names: tool_names)
  unless built.built?
    puts JSON.generate({ "built" => false, "refusal" => built.refusal.to_s })
    next
  end

  lowered = lower.stage(built: built, node: caller, model_defaults: defaults)
  unless lowered.lowered?
    puts JSON.generate({ "built" => true, "refusal" => lowered.refusal.to_s })
    next
  end

  line = nil
  ActiveRecord::Base.transaction do
    ActiveRecord::FixtureSet.reset_cache
    ActiveRecord::FixtureSet.create_fixtures(fixtures, Dir[File.join(fixtures, "*.yml")].map { |path| File.basename(path, ".yml") })

    waited = answered_loop.()
    r1 = waited.agent_loop_nodes.find_by!(node_key: "r1")
    spine = tasks::Tip.new(spine: tasks::Known.of(r1), waits: [tasks::Known.of(r1)], reads: [], mark: tasks::Compile::ROUND,
      detached: false, lifetime: "conversation", wake: "auto")
    append.(waited, [tasks::Step.inheriting(r1, key: "head")], spine)
    append.(waited, lowered.steps, tasks::Tip.seed(tasks::Compile::BRANCH), head: "head")
    head = waited.agent_loop_nodes.find_by!(node_key: "head")

    detached = answered_loop.()
    append.(detached, lowered.steps, tasks::Tip.seed(tasks::Compile::BRANCH).with(detached: true))
    settle_all.(detached)
    line = {
      "built" => true,
      "head" => Array(head.input_from_node_keys) - ["r1"] + Array(head.result_from_node_keys),
      "settled" => AgentLoops::WakeContinuation.sinks(detached.reload).map(&:node_key),
      "undelivered" => AgentLoops::WakeContinuation.undelivered(detached).map(&:node_key),
      "bound" => tasks::Compile::KERNEL_MAX_INPUT_FROM,
    }
    raise ActiveRecord::Rollback
  end
  puts JSON.generate(line)
end
