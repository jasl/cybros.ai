module Nexus
  module ToolRegistry
    # The memory family's entries (`nexus.memory.*`, the one overridable
    # namespace): `read`, `write`, `edit`, `ls`, `grep`, `delete`. ONE
    # SLICE of the live table: the bytes of each entry are the kernel's
    # model-facing text and are pinned by `contracts:generate`
    # (tools.json); `LIVE` is the four slices in order. `Tool` and the
    # effect constants are the registry's own.
    module Memory
      TOOLS = [
        # Logical memory paths address database documents; the runner's
        # similarly named file tools address the runner filesystem.
        Tool.new(
          canonical: "nexus.memory.read",
          name: "memory_read",
          template: <<~TEXT.strip,
            Read one memory document. Memory is DURABLE and belongs to the
            kernel, not to this machine: what you write survives this loop,
            a restart, and a different runner picking up the next round.
            That is what makes it different from the file tools, which write
            to whichever machine happens to be running you.

            Paths begin with an available logical root. A configured root such
            as `group/...` can name shared memory; its access may be read only.
            The default roots are their scopes. `workspace/...` is shared with
            everyone who can open this workspace, including other agents and
            every human member — do not put anything there you would not
            show them. `conversation/...` belongs to one conversation and is
            unavailable from a standalone run.
            `user/...` belongs to the person this turn answers to and follows
            them across workspaces; their other agents can read it.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "path" => { "type" => "string",
                          "description" => "Logical memory path, e.g. conversation/notes.md or group/notes.md" },
              "offset" => { "type" => "integer",
                            "description" => "1-indexed line number to start reading from" },
              "limit" => { "type" => "integer",
                           "description" => "Maximum number of lines to read" },
            },
            "required" => ["path"],
          },
          effect_profile: MEMORY_READ,
          executor: "AgentRuns::Memory::Run", job: "AgentRuns::MemoryJob",
        ),
        Tool.new(
          canonical: "nexus.memory.write",
          name: "memory_write",
          template: <<~TEXT.strip,
            Write one memory document, replacing it whole. Memory is DURABLE
            and belongs to the kernel: what you write here survives this
            loop, a restart, and a different runner picking up the next
            round — unlike the file tools, which write to whichever machine
            happens to be running you.

            Use it for what the next round, or the next session, would
            otherwise have to rediscover: the goal, the decisions taken and
            why, what is done and what remains. Rewrite the whole document
            each time; there is no history to consult, and none is needed
            when the document says what is true now.

            Creates a missing path or replaces the current document in full.
            Read first to preserve information you still need; use
            {{memory_edit}} to change one exact passage instead.

            Paths begin with an available logical root. A configured root such
            as `group/...` can name shared memory; its access may be read only.
            The default roots are their scopes. `workspace/...` is shared with
            everyone who can open this workspace. `conversation/...` belongs
            to one conversation and is unavailable from a standalone run.
            `user/...` belongs to the person this turn answers to and follows
            them across workspaces; their other agents can read it.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "path" => { "type" => "string",
                          "description" => "Logical memory path, e.g. conversation/notes.md or group/notes.md" },
              "content" => { "type" => "string",
                             "description" => "The document's complete new text." },
            },
            "required" => %w[path content],
          },
          effect_profile: MEMORY_WRITE,
          executor: "AgentRuns::Memory::Run", job: "AgentRuns::MemoryJob",
        ),
        Tool.new(
          canonical: "nexus.memory.edit",
          name: "memory_edit",
          template: <<~TEXT.strip,
            Replace one exact passage inside a memory document, leaving the
            rest alone. `old_text` must appear EXACTLY ONCE in the document;
            if it appears twice or not at all the edit is refused and
            nothing changes. Read the document first to choose an exact
            passage; the match is checked against its current content.

            Prefer {{memory_write}} when you are rewriting most of a document —
            it is simpler and it cannot half-apply.

            This edits DURABLE memory, not a file on the machine running
            you: the change survives this loop and every runner after it.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "path" => { "type" => "string",
                          "description" => "Logical memory path, e.g. conversation/notes.md or group/notes.md" },
              "old_text" => { "type" => "string",
                              "description" =>
                                "Exact text to replace. Must occur exactly once." },
              "new_text" => { "type" => "string",
                              "description" => "Replacement text." },
            },
            "required" => %w[path old_text new_text],
          },
          effect_profile: MEMORY_EDIT,
          executor: "AgentRuns::Memory::Run", job: "AgentRuns::MemoryJob",
        ),
        Tool.new(
          canonical: "nexus.memory.ls",
          name: "memory_ls",
          template: <<~TEXT.strip,
            List memory documents with their paths, sizes and
            when they were last written. Call it before assuming memory is empty — a previous
            run, another agent, or a human may have left something here, and
            this store OUTLIVES the loop and the machine.

            Give no path to see all selected bindings, or a prefix such as
            `workspace/` to narrow. This lists DURABLE memory, never the
            files on the machine running you.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "path" => { "type" => "string",
                          "description" =>
                            "Optional scope or prefix to narrow the listing." },
            },
          },
          effect_profile: MEMORY_READ,
          executor: "AgentRuns::Memory::Run", job: "AgentRuns::MemoryJob",
        ),
        Tool.new(
          canonical: "nexus.memory.grep",
          name: "memory_grep",
          template: <<~TEXT.strip,
            Search memory documents for a regular expression, exactly as
            grep does. This is a LITERAL text search over the documents'
            lines — it does not understand meaning, rank results, or find
            anything a plain pattern would miss. If a search returns
            nothing, try a different pattern or list the documents; do not
            conclude memory is empty.

            Answers matching lines as `path:line: text`, in path order. It
            searches DURABLE memory — what previous runs and other agents
            left here — never the files on the machine running you.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "pattern" => { "type" => "string",
                             "description" => "Regular expression to match against each line." },
              "path" => { "type" => "string",
                          "description" => "Optional scope or prefix to narrow the search." },
              "ignore_case" => { "type" => "boolean",
                                 "description" => "Match case-insensitively." },
              "limit" => { "type" => "integer",
                           "description" => "Maximum matching lines to return." },
            },
            "required" => ["pattern"],
          },
          effect_profile: MEMORY_READ,
          executor: "AgentRuns::Memory::Run", job: "AgentRuns::MemoryJob",
        ),
        Tool.new(
          canonical: "nexus.memory.delete",
          name: "memory_delete",
          template: <<~TEXT.strip,
            Delete one memory document from DURABLE memory — not a file on
            the machine running you. It is gone for good: there is no
            history and no recycle bin. A conversation that was forked from
            this one keeps its own copy; deleting here does not reach it.
            Deletes the document currently at the given path.
          TEXT
          parameters: {
            "type" => "object",
            "properties" => {
              "path" => { "type" => "string",
                          "description" => "Logical memory path, e.g. conversation/notes.md or group/notes.md" },
            },
            "required" => ["path"],
          },
          effect_profile: MEMORY_WRITE,
          executor: "AgentRuns::Memory::Run", job: "AgentRuns::MemoryJob",
        ),
      ].freeze
    end
  end
end
