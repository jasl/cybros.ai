require "test_helper"

# THE DELEGATE SUMMARIZER AS AN EXTENSION: rho
# answers the kernel's compaction delegate with its own prompt on its own
# model — one OneShot on the member plane, followed under the clamp, the
# text committed as the row's answer. Loaded alone on a fresh handle, with
# a fake member plane that records what was placed.
class CompactionExtensionTest < Minitest::Test
  Compaction = Rho::Extensions::Compaction
  SummarizeHistory = Compaction::SummarizeHistory
  Result = Rho::Runner::Result

  # The member plane a tool reaches: one workspace, one `one_shots` lane
  # that records the create and answers a scripted sequence of fetches.
  class Lane
    attr_reader :creates, :fetches

    def initialize(statuses:)
      @statuses = statuses
      @creates = []
      @fetches = 0
    end

    def create(**fields)
      @creates << fields
      CybrosAgent::Api::OneShotsContext::Accepted.new(one_shot: one_shot(@statuses.first), replayed: false)
    end

    def fetch(_public_id)
      @fetches += 1
      one_shot(@statuses[[@fetches, @statuses.length - 1].min])
    end

    private

      def one_shot(status)
        result =
          case status
          when :running then nil
          when :completed then CybrosAgent::Api::OneShotResult.new(
            status: "completed", finish_quality: nil, output_text: "Mock summary", usage: nil, timing: nil,
            error: nil, reasoning: nil, output_files: nil
          )
          else CybrosAgent::Api::OneShotResult.new(
            status: status.to_s, finish_quality: nil, output_text: nil, usage: nil, timing: nil,
            error: CybrosAgent::Api::OneShotError.new(code: "provider_refused", attempt_budget_spent: true),
            reasoning: nil, output_files: nil
          )
          end
        CybrosAgent::Api::OneShot.new(
          public_id: "os-1", workload: "text_generation", status: result ? result.status : "running",
          model: nil, billing_subject: nil, created_at: nil, updated_at: nil, usage_summary: nil, result: result
        )
      end
  end

  Client = Struct.new(:lane) do
    def workspace(public_id)
      raise "wrong workspace #{public_id}" unless public_id == "ws-1"

      Struct.new(:one_shots).new(lane)
    end
  end

  def setup
    super
    @sleeps = []
    @lane = nil
  end

  def config(model: "openrouter/summarizer", default: nil)
    Rho::Config.from_hash("compaction" => { "mode" => "delegate", "model" => model }.compact,
      "default_model" => default)
  end

  def bound(statuses: %i[running running completed], plane: :present, config: self.config, default_workspace: "ws-1")
    @lane = Lane.new(statuses: statuses)
    client = Client.new(@lane)
    host = Rho::Extensions::Host.new(
      home: RhoTest.host.home, log: nil, clock: -> { Time.now }, config: config, processes: nil,
      member_plane: ->(host_public_id: nil, workspace_public_id: nil) do
        if plane == :present
          Rho::Extensions::MemberPlane.new(client: client,
            workspace_public_id: workspace_public_id || (%w[al-1 conv-1].include?(host_public_id) ? "ws-1" : default_workspace))
        end
      end
    )
    api = Rho::Extensions::Api.new(host: host, extension_name: Compaction::NAME, source: "<test>")
    Compaction.register(api)
    SummarizeHistory.sleeper = ->(seconds) { @sleeps << seconds }
    api.tools.sole_tool.klass.new(env: nil)
  end

  def context(loop: "al-1", task: "k1", conversation: nil, workspace: nil)
    Rho::Runner::ExecutionContext.new(agent_loop_public_id: loop, task_key: task, conversation_public_id: conversation,
      workspace_public_id: workspace)
  end

  def call(tool, args = { "history" => "User: hi\nAssistant: hello", "retained_tail" => "Tool bash (completed)" },
           ctx: context)
    Rho::Runner::ExecutionContext.with(ctx) { tool.call(args) }
  end

  def test_summaries_stay_in_the_original_workspace_when_the_default_changes
    [context, context(loop: "new-turn", conversation: "conv-1"), context(loop: "child-turn", conversation: "unfollowed-child", workspace: "ws-1")].each do |owner|
      tool = bound(default_workspace: "ws-2")

      assert_equal Result.ok("Mock summary", title: "summarized"), call(tool, ctx: owner)
      assert_equal 1, @lane.creates.length
    end
  end

  # The extension ships in the default set and registers exactly the one
  # tool, announced with the profile the arm freezes on the row and the
  # park that bounds a dead rho's cost.
  def test_the_extension_ships_one_replayable_tool_with_a_two_minute_park
    assert_includes Rho::Extensions::DEFAULT_EXTENSIONS, Compaction
    registry = Rho::Extensions.load(host: RhoTest.host, extensions: [Compaction]).registry
    entry = registry.entries.find { |candidate| candidate.name == "summarize_history" }
    assert_equal Compaction::TOOL_NAME, entry.name
    assert_equal({ "kind" => "pure", "destructive" => false, "world" => "closed",
                   "idempotency" => "intrinsic", "reconciliation" => "none" }, entry.effect_profile,
      "replayable: a re-run costs one OneShot, so the delegate expires timed_out, never uncertain")
    assert_equal 120_000, entry.timeout_ms
    assert_equal %w[history], entry.schema.fetch("required")
    assert_nil Rho::Runner::Extensions::Tool.prompt_snippet(SummarizeHistory), "never offered to a model"
  end

  # RHO'S OWN PROMPT, pinned byte for byte: the whole point of a delegate
  # is the agent's own text, and a change here is a change to what every
  # delegated summary says.
  def test_the_summarizer_prompt_is_rhos_own_and_pinned
    assert_equal <<~TEXT.strip, Compaction::INSTRUCTIONS
      You are summarizing the earlier part of a coding agent's conversation so the agent can continue with less context. The history below is what happened; the retained tail is what the agent will still see verbatim after your summary.

      Write the summary under these headings, each as short as the facts allow:
      - Goal: what the person asked for, in their words where it matters.
      - Done: the changes made, by file and function, and the commands run with their results.
      - Findings: the facts established (versions, paths, behaviours, failing tests) that later steps depend on.
      - Open: what is not finished, decisions still pending, and the person's standing instructions.

      Rules:
      - Tool results were cut to their head and may be incomplete: do not invent values, counts, paths or outputs that are not in the text. Name the file or command to re-read instead ("re-run the tests to see the failing names").
      - Keep exact identifiers verbatim: file paths, function names, error messages, commit hashes, task keys.
      - Write only the summary. No preamble, no closing remark, no advice to the reader.
    TEXT
  end

  # One OneShot on the member plane, followed until it finishes, its text
  # the answer: the input is rho's prompt, then the history, then the tail;
  # the key is the row's, so a transport retry replays rather than bills.
  def test_the_handler_places_one_one_shot_and_answers_its_text
    tool = bound
    result = call(tool)

    assert_equal Result.ok("Mock summary", title: "summarized"), result
    create = @lane.creates.sole_create
    assert_equal "text_generation", create.fetch(:workload)
    assert_equal "openrouter/summarizer", create.fetch(:model)
    assert_equal "summarize_history:al-1:k1", create.fetch(:idempotency_key)
    assert_equal "#{Compaction::INSTRUCTIONS}\n\nUser: hi\nAssistant: hello\n\nTool bash (completed)",
      create.fetch(:input)
    assert_equal 2, @lane.fetches, "followed until the result envelope arrived"
    assert_equal [Rho::OneShotRun::POLL_SECONDS] * 2, @sleeps
  end

  def test_the_model_falls_to_default_model_when_compaction_names_none
    tool = bound(config: config(model: nil, default: "dev/mock-text"))
    call(tool, { "history" => "h" })

    assert_equal "dev/mock-text", @lane.creates.sole_create.fetch(:model)
    assert_equal "#{Compaction::INSTRUCTIONS}\n\nh", @lane.creates.sole_create.fetch(:input),
      "no tail, no trailing blank"
  end

  # A summarizer that could not run is a FAILED row under absorb — never a
  # `completed, is_error` text the composer might read as a summary.
  def test_a_failed_one_shot_raises_so_the_row_fails
    tool = bound(statuses: %i[running failed])

    error = assert_raises(Compaction::NoSummary) { call(tool) }
    assert_match(/the summarizer OneShot failed: provider_refused/, error.message)
  end

  def test_no_member_plane_is_an_error_the_model_reads
    tool = bound(plane: :absent)

    result = call(tool)
    assert_predicate result, :is_error
    assert_match(/no member plane/, result.content)
    assert_empty @lane.creates
  end

  # THE CLAMP'S CHECKPOINT: a follow that never finishes ends at the
  # context's cancellation, never at its own patience.
  def test_cancellation_mid_follow_raises_cancelled
    tool = bound(statuses: %i[running running running])
    ctx = context
    SummarizeHistory.sleeper = ->(_seconds) { ctx.cancel(:deadline) }

    assert_raises(Rho::Runner::ExecutionContext::Cancelled) { call(tool, ctx: ctx) }
    assert_equal 1, @lane.creates.length
  end
end

# `sole` is ActiveSupport's; these two are the test's own spelling of it.
class Array
  def sole_tool = tap { |list| raise "expected one tool, got #{list.length}" unless list.length == 1 }.first
  def sole_create = sole_tool
end
