module Nexus
  # The flat kernel verbs a model gets beside `compose` — `task` (one bounded
  # job to a new agent), `ask` (one question to the person), `spawn` (a
  # persistent conversation with another agent) and the three verbs on such a
  # conversation: `send`, `status`, `cancel` — and `skill`, the load of one
  # skill's instructions. Published from the registry so every client and
  # every probe sends the same bytes.
  module Tools
    TASK = ToolRegistry.function_definition("task")
    WAIT = ToolRegistry.function_definition("wait")
    ASK = ToolRegistry.function_definition("ask")
    SPAWN = ToolRegistry.function_definition("spawn")
    SEND = ToolRegistry.function_definition("send")
    STATUS = ToolRegistry.function_definition("status")
    CANCEL = ToolRegistry.function_definition("cancel")
    SKILL = ToolRegistry.function_definition("skill")
  end
end
