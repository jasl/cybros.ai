module Runs
  module Delegations
    module Observers
      module_function

        def append_await(call:, prompt:)
          run = call.run
          await_key = Spawn::Run.await_key(call.node_key)
          return Conversations::Outcome.accepted(nil) if run.tasks.exists?(node_key: await_key)

          step = Tasks::Step::Ask.new(key: await_key, prompt: prompt, on_failure: "absorb")
          # A graph-authored call has no provider pairing. Its wait and result
          # consumers follow the first reply, including non-model consumers.
          result = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
            run: run, steps: [step], tip: KernelTool.branch_tip(call),
            origin: "kernel", expansion_parent: call, holder: :kernel,
            head: (KernelTool.continuation_of(call)&.node_key if call.tool_call_id),
            replaces: (call.node_key unless call.tool_call_id)
          ))
          # A twin run appended it under the loop lock first.
          return Conversations::Outcome.accepted(nil) if result.applied? || result.outcome == :duplicate_task_key

          detail = result.errors.first&.fetch("code", nil) || result.outcome
          Conversations::Outcome.refused(detail)
        end
    end
  end
end
