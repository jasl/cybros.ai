module CybrosAgent
  module Api
    # One Workspace's AGENT RUN collection — the author half of a surface
    # that shipped with only its runner half. Until this, this SDK could
    # claim and answer tool work and had no way to create the run that
    # work belongs to, so anything that wanted one hand-wrote HTTP.
    #
    # STEPS IN, WRITTEN ORDER. A caller writes `Steps` values (or their
    # wire Hashes) in the order the work runs; `parallel` names a fan; the
    # kernel places every edge and every barrier — no client authors one,
    # which is what keeps the graph sound. Reading it whole is
    # `run(id).graph`; how far it got is `run(id).phases`.
    #
    # Everything that acts on ONE run lives on `run(public_id)`,
    # for the reason the conversation surface splits the same way: the deep
    # surface does not read well as a flat method list with three
    # identifiers per call.
    class RunsContext
      include RunProjections
      include Fields

      # The request composition's fixed shell: the seed's word
      # and the mode a caller never chooses — see `request`.
      REQUEST_PROMPT_MECHANISM = "raw".freeze
      REQUEST_APPROVAL_MODE = "bypass".freeze
      # The kernel's refusal of a second `start`: on a replayed create this
      # means "already started", which is the composition's own outcome.
      NOT_STARTABLE = "not_startable".freeze

      attr_reader :workspace_public_id

      def initialize(dispatch:, workspace_public_id:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
      end

      # THE TWO QUESTIONS A PERSON ASKS OF A LIST, plus the one ordering
      # they want. `status` takes a set (an Array or a comma-separated
      # String) and `attention: "any"` is "needs a person" whatever the
      # status — a reason stands on a `running` run too. `order: "desc"` is
      # most-recent-first, and the cursor carries that direction, so a page
      # continued the other way is refused rather than walked backwards.
      def list(after: nil, limit: nil, status: nil, attention: nil, order: nil)
        params = query(after:, limit:, status: status && Array(status).join(","), attention:, order:)
        page(Run, @dispatch.call(path, params: params), "runs")
      end

      # CREATE WITH THE SEED BATCH. A run is created with the work it
      # starts from, because a run with no tasks has nothing to schedule
      # and would only ever be an id waiting for a second call.
      #
      # It is created STOPPED: `start` is a separate verb, so a caller can
      # inspect what it authored — or refuse it — before anything spends a
      # model call.
      #
      # The caller's own Idempotency-Key is required; the SDK never mints
      # one, because a retry the caller cannot recognize as a retry is how
      # one run becomes two.
      #
      # THE DELIVERABLE is never named: the envelope's end is the run's
      # answer by construction, and the receipt says which key that is.
      #
      # THE SHELL. `approval_mode` is REQUIRED — `bypass`, `ask` or `rules`:
      # nothing is silently defaulted, the kernel refuses nil
      # `invalid_approval_mode`, and so an omission is an ArgumentError
      # here, before any request. `approval_rules` is the optional rule
      # list, sent as written — the kernel is the one
      # evaluator and refuses a malformed list `invalid_approval_rules`.
      # `prompt_mechanism` is the shell's word: "raw" — the
      # seed step's own prompt, instructions and tools ARE the request;
      # "default" / "assembly" — the kernel compiles the seed once at
      # create (the creator's slots, the room's memory, the words; under
      # "assembly" the creator profile's own template, else the built-in
      # order) and refuses the seed step's `instructions` by name
      # (`invalid_steps` / `instructions_raw_only`); "assembly" on a
      # creator with no template is 422 `prompt_template_missing`.
      #
      # `default_runner_executor_public_id` supplies the mutable convenience
      # default for unqualified future Runner tools. Each explicit route keeps
      # its own target, and accepted tasks retain that captured target even if
      # the default later changes. Nil leaves the host without a default.
      def create(steps:, idempotency_key:, approval_mode:, billing_subject: UNSET,
                 prompt_mechanism: UNSET, approval_rules: UNSET, default_runner_executor_public_id: UNSET)
        required_string(idempotency_key, "idempotency_key")
        required_string(approval_mode, "approval_mode")
        raise ArgumentError, "steps must be a non-empty Array" unless
          steps.is_a?(Array) && !steps.empty?

        body = fields(
          steps: Steps.envelope(steps), billing_subject:, prompt_mechanism:, approval_mode:,
          approval_rules:, default_runner_executor_public_id:
        )

        result = @dispatch.call_accepting(
          path, method: :post, body: { "run" => body },
          headers: { "Idempotency-Key" => idempotency_key },
          success: [201, 200]
        )
        CreatedRun.new(
          run: shape(Run, result.body, "run"),
          receipt: result.body["receipt"],
          # A REPLAY IS A 200 AND A CREATE IS A 201: the retry could not
          # have known the id, so the standing run is the answer.
          replayed: result.status != 201
        )
      end

      # THE REQUEST HALF OF THE EXECUTOR RELAY: something only
      # a runner can answer — a file's bytes, a process's log — asked for as
      # a ONE-TASK standalone run on this same task-grained surface, no
      # second door and no second kind. A composition over two verbs this
      # context already has: `create` with a single `tool` step under `raw`
      # (the seed IS the deliverable), the runner named so the row is
      # addressed to it from birth, `approval_mode: "bypass"` — inert for
      # an author-origin row: the step is granted by its origin unless a
      # rule NAMING `author` says otherwise, so `approval_rules` is the
      # only shell a caller shapes — then `start`, because creation authors
      # and starting dispatches: an unstarted request is a `queued` row
      # nothing expires. A replayed create answers a run already started,
      # and its `start` refuses `not_startable`; that refusal IS "already
      # started" and the composition treats it so.
      #
      # `timeout_ms` is the step's own clock and BEATS the runner's
      # announced park (the kernel's rule: step first); nil leaves the
      # announced park, else the kernel's default, in force — a large
      # capture over a slow link is the caller's to size. The answer is
      # read with `wait_for_tool_result` on the context this returns.
      def start_tool_call(runner_executor_public_id:, tool:, idempotency_key:, input: {}, timeout_ms: nil,
                  approval_rules: UNSET)
        required_string(runner_executor_public_id, "runner_executor_public_id")
        required_string(tool, "tool")
        raise ArgumentError, "input must be a Hash" unless input.is_a?(Hash)

        created = create(
          steps: [Steps::Tool.new(name: tool, input: input, timeout_ms: timeout_ms,
            key: RunContext::TOOL_CALL_TASK_KEY,
            route: { "kind" => "runner", "runner_executor_public_id" => runner_executor_public_id })],
          idempotency_key: idempotency_key, approval_mode: REQUEST_APPROVAL_MODE,
          prompt_mechanism: REQUEST_PROMPT_MECHANISM, approval_rules: approval_rules,
          default_runner_executor_public_id: runner_executor_public_id
        )
        context = run(created.run.public_id)
        begin
          context.start
        rescue Conflict => error
          raise unless error.code == NOT_STARTABLE
        end
        context
      end

      def fetch(public_id) = shape(Run, @dispatch.call(run_path(public_id)), "run")

      def run(public_id)
        RunContext.new(
          dispatch: @dispatch, workspace_public_id: @workspace_public_id,
          run_public_id: public_id
        )
      end

      private

        def path = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs"

        def run_path(public_id)
          "#{path}/#{required_string(public_id, "public_id")}"
        end
    end
  end
end
