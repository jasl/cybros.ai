module CybrosAgent
  # The executor transport plane: the Nexus → Agent direction.
  # It carries the transport credential and proves which delivery address this
  # process is. It deliberately reaches no member resource — an executor
  # bootstrap that called a member endpoint would break the containment a
  # runner depends on.
  class ExecutorClient < Api::BaseClient
    EXECUTOR_PATH = "/agent_api/v1/executor".freeze
    ANNOUNCEMENT_PATH = "#{EXECUTOR_PATH}/announcement".freeze
    INBOX_PATH = "#{EXECUTOR_PATH}/inbox".freeze
    PROGRESS_PATH = "#{EXECUTOR_PATH}/progress".freeze

    # This address's own self-description. The credential names it; nothing
    # here is submitted by the caller.
    def executor
      shape(Api::ExecutorDescription, dispatch.call(EXECUTOR_PATH))
    end

    # Replace the complete role map. Each role owns its tools, documents and
    # environment; omitting an optional role withdraws it for future claims.
    def announce(services:)
      shape(Api::ExecutorDescription, dispatch.call(ANNOUNCEMENT_PATH,
        method: :put, body: { "services" => services }))
    end

    # THE INBOX: every row the kernel addressed to this
    # credential's executor, across every live run — the executing half of
    # the agent-run surface, and it lives on THIS plane alone. A runner is
    # `executor_client` alone and can now work with it.
    def inbox
      Api::ExecutorInboxContext.new(dispatch: dispatch)
    end

    # THE CAPTURES THIS ADDRESS PUBLISHES: `uploads.create(path)`
    # stages a file as this executor's own; a `ResourceLink` block in a
    # commit's `content` names it, and a reader of that result fetches it on
    # the member plane. Nothing here reads a capture back.
    def uploads
      Api::ExecutorUploadsContext.new(dispatch: dispatch)
    end

    # One row of the inbox: where it is claimed and its answer committed.
    def inbox_task(run_public_id:, task_key:)
      Api::ExecutorTaskContext.new(
        dispatch: dispatch, run_public_id: run_public_id, task_key: task_key
      )
    end

    # ONE EPHEMERAL FRAME (executor.md "Progress"): what this executor is
    # doing right now, for whoever is watching — never for the model, never
    # stored. ONE verb, the key inside the frame: `{run_public_id,
    # task_key, claim_token, text_tail?, structured?}` posts INSIDE a claim
    # (this address must be the row's current claimant — `not_claimant`);
    # `{conversation_public_id | run_public_id, process_id, lines[],
    # exit?}` posts a process this runner owns by its HOST (this address
    # must be the host's bound runner — `not_bound`). `202` whether the
    # kernel broadcast the frame or dropped it for cadence: the kernel
    # admits ONE frame per key per `min_interval_ms` (size_bounds.json,
    # `progress_min_interval_ms`), a faster poster loses frames and never a
    # task. The two fences raise `Api::Conflict`; a frame over
    # `envelope_bound` or keyed by neither kind is unprocessable. Answers nil.
    def report_progress(frame)
      frame = Hash.try_convert(frame)
      raise ArgumentError, "frame must be a Hash" unless frame

      dispatch.call(PROGRESS_PATH, method: :post, body: { "frame" => frame }, success: 202)
      nil
    end

    SHAPES = {
      Api::ExecutorDescription => { executor: [:shape, Api::ExecutorAddress], measured_at: :string },
      Api::ExecutorAddress => {
        public_id: :string,
        kind: :string,
        status: :string,
        display_name: :optional_string,
        credential_epoch: :integer,
        presence: :string,
        last_seen_at: :optional_string,
        connected_at: :optional_string,
        agent_public_id: :optional_string,
        registration_identifier: :optional_string,
        assignment_scope: :optional_string,
        service_roles: :string_list,
      },
    }.freeze
  end
end
