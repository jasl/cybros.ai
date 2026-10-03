module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # WHAT A TOOL RETURNS, and the distinction that makes the round work.
    #
    # `is_error` is DATA: the tool RAN and returned an error, the model reads
    # it and self-corrects. A tool that could not run AT ALL never builds one
    # of these — it raises, and the runner answers `outcome: "failed"`, which
    # takes the task's own failure policy. Collapsing the two costs the model
    # its chance to fix its own call.
    #
    # THE THREE CHANNELS the commit carries (executor.md, "Commit"), one
    # meaning each — and getting this wrong sends a tool author down a path
    # where their structure silently never arrives:
    #
    # `content` is the MODEL's: the only channel a model reads, its text
    # verbatim. `structured_content` (MCP's `structuredContent`) is the
    # UI's: stored whole and served back on the task read, where a client
    # picks it up, and NEVER rendered to the model — the server serializes
    # nothing into the text position, so a result with structure and no
    # content hands the model `""`. A tool that wants the model to read its
    # structure puts the words in `content` beside it: the model reads the
    # prose, the client reads the structure. A kernel-marked lifecycle hook
    # also uses structured_content for its closed continuation decision;
    # an ordinary tool result never gains that authority. `title` is the UI's one-line
    # header. `metadata` is the MODEL-INVISIBLE carrier (executor.md,
    # ONE reserved key, `checkpoint`): stored verbatim by the kernel,
    # served on the task read, never rendered to a model — the runner's
    # own record of the world before a call (the capture hook attaches it to the first write-kind result that completes; `world_ restore` answers its undo on it). nil on every result that carries
    # none, and `submit` sends nothing then.
    #
    # `files` are CAPTURES: paths on this machine the
    # tool wants a CLIENT to fetch — a screenshot, a spilled log, the file
    # `files_bytes` was asked for. A tool has no reach to the transport, so
    # it names the paths and the run uploads them after the handler returns
    # (`TaskRun#submit`, the ONE upload site) and links each as a
    # `resource_link` block beside the text. The text still names the path
    # for the model (`read` on the same runner); the link is for the
    # client beside it, never instead of it. `files_required` marks a tool
    # whose purpose is publication: a capture refusal then becomes an error
    # result, while incidental screenshots/spills keep their ordinary answer.
    Result = Data.define(:content, :structured_content, :is_error, :title, :files, :metadata, :files_required) do
      class << self
        def ok(content, structured_content = nil, title: nil, files: [], metadata: nil, files_required: false)
          new(content:, structured_content:, is_error: false, title:, files:, metadata:, files_required:)
        end

        def error(content, structured_content = nil, title: nil, files: [], metadata: nil, files_required: false)
          new(content:, structured_content:, is_error: true, title:, files:, metadata:, files_required:)
        end
      end

      def initialize(content:, structured_content: nil, is_error: false, title: nil, files: [], metadata: nil, files_required: false)
        super(content:, structured_content:, is_error:, title:, files: Array(files).map(&:to_s).freeze,
          metadata:, files_required:)
      end
    end
  end
end
