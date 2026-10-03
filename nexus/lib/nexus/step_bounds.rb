module Nexus
  # The bounds the step compiler (`AgentLoops::Tasks::Compile`) measures a
  # step tree against, and the key format it reads each step's key by, free
  # of Rails so a reader outside the application — the compose bench's
  # static lowering — reads these values rather than a copy of them.
  module StepBounds
    # A model-authored append's leaves: a 40-call fan is ordinary model
    # output, so the kernel's bound sits above a client's request hygiene.
    KERNEL_MAX_TASKS_PER_REQUEST = 257
    # The whole step tree, as JSON bytes.
    MAX_TASKS_PAYLOAD_BYTES = 1_048_576
    # ONE tool step's input, measured where the row measures it: the
    # `tool_input` column's bound, a `SizeBounds` name.
    TOOL_INPUT_BOUND = :envelope_bound
    # The key every node row carries (`AgentLoopNode#node_key`): the compiler
    # refuses a step whose key, or a wait whose awaited task, does not match
    # it (`invalid_task_key`).
    NODE_KEY_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  end
end
