module CybrosAgent
  module Api
    # ONE TASK OF A RUN, from the member's side: the PERSON's verb
    # (`resolve` answers an await), the DECIDER's verbs (`retry`,
    # `abandon`, `cancel`, `compact`) and the APPROVER's verbs (`approve`,
    # `deny`) on a tool call resting at `needs_approval`.
    #
    # The executing half — claiming a parked tool call and committing its
    # answer — is not here and not on any member door: it is the
    # EXECUTOR plane's, `ExecutorClient#inbox_task`. A member bearer holds
    # standing on the workspace; it holds no address, and only an address
    # is handed work.
    class RunTasksContext
      include RunProjections
      include Fields

      attr_reader :workspace_public_id, :run_public_id, :task_key

      def initialize(dispatch:, workspace_public_id:, run_public_id:, task_key:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
        @run_public_id = required_string_snapshot(run_public_id, "run_public_id")
        @task_key = required_string_snapshot(task_key, "task_key")
      end

      # ANSWER AN AWAIT — the human half of the rendezvous: the door onto
      # the question a run is holding for a person.
      #
      # `resolution_token` IS OPTIONAL, and which awaits need it is not a
      # choice the caller makes. An await this client APPENDED came back
      # with its token in the append receipt's `resolution_tokens`, and
      # that token is the second factor its answer must present. An await
      # created by a model's `ask` tool or a task operation's ask step
      # issues no token, so there is none to send. The caller instead needs
      # write standing on the run, including its conversation when hosted.
      #
      # Flat, not wrapped: the door reads the envelope straight off the
      # request parameters, so a nesting key sends the token nowhere.
      def resolve(resolution_token: UNSET, content: UNSET,
                  structured_content: UNSET, result_type: UNSET, outcome: UNSET)
        token = UNSET.equal?(resolution_token) ? UNSET :
          required_string(resolution_token, "resolution_token")
        body = fields(resolution_token: token, content:, structured_content:, result_type:, outcome:)

        @dispatch.call("#{path}/resolution", method: :post, body: body)
      end

      # THE THREE ADJUDICATION DOORS, and until now a halted run had no
      # client at all: the kernel routed, implemented and documented these,
      # and the only way to reach one was hand-rolled HTTP. A run resting
      # on an unresolved `halt` failure has no clock — it stands there until
      # somebody decides — so these are the verbs that decide.
      #
      # RETRY re-queues the failed task under its own lineage; ABANDON
      # settles the failure as resolved so the run moves past it. Both
      # answer the task as it now stands.
      # Naming a model changes only the failed model task's next execution;
      # completed tools stay settled. Omission keeps its current selection.
      def retry(model: UNSET, reasoning_effort: UNSET, reasoning_enabled: UNSET)
        body = fields(model: optional_fields(model:, reasoning_effort:, reasoning_enabled:))
        adjudicated(@dispatch.call("#{path}/retry", method: :post, body: body.empty? ? nil : body))
      end

      def abandon = adjudicated(@dispatch.call("#{path}/abandon", method: :post))

      # CANCEL A BRANCH — work a model started, by the key the model saw
      # (`r3t1`, the `task` call) or any node of it. The branch settles
      # `canceled` with a resolution, so a blocking consumer runs and reads
      # `status="canceled"`; a background answer is delivered canceled. The
      # mainline is `stop`'s: a round or a mainline fan member answers 409
      # `not_a_branch`, a settled branch 409 `already_terminal`.
      def cancel = adjudicated(@dispatch.call("#{path}/cancel", method: :post))

      # THE APPROVER'S VERBS. A tool call the run's mode or a
      # rule parked rests at `needs_approval`, addressed to the host's
      # agent application, on a 24 h clock; the run stays `running` and
      # announces `approval_required`. Any principal with write standing
      # on the workspace decides — the agent application acting for its
      # person included — and the fact on the answered task says who and
      # of what kind (`approval: {origin: human | agent, decided_by,
      # decided_at}`).
      #
      # APPROVE releases the call past the stage through the one grant site
      # the `bypass` path also takes; it re-runs the addressing site, and a
      # call whose effect profile changed under the park RESTS AGAIN with
      # the new profile (200, still `needs_approval`) so the person reads
      # it before granting. DENY fails the call `approval_denied` with the
      # reason as `error.detail`; the row's own `on_failure` decides the
      # cascade — a model-composed call is `absorb`, so the next round reads
      # the declined sentence and corrects itself. Both refuse 409
      # `not_awaiting_approval` on a row not resting for an approver.
      def approve = adjudicated(@dispatch.call("#{path}/approve", method: :post))

      # No reason is an EMPTY body, never `reason: nil` — the door reads a
      # non-text reason as 400 `parameter_invalid`, and nil is not text.
      def deny(reason: nil)
        adjudicated(@dispatch.call("#{path}/deny", method: :post, body: { "reason" => reason }.compact))
      end

      # COMPACT repairs a round by authoring a summarizer for it, so its
      # answer names both: 202, because the summary is work that has been
      # started rather than finished.
      def compact
        shape(CompactedRound, @dispatch.call("#{path}/compact", method: :post, success: 202))
      end

      # THE DEBUG DOOR ON A ROUND: the round's sealed
      # request — exactly the entries and the request options (`tools`
      # among them; the assembled lane's system text rides the list, not
      # `instructions`) — derived from the sealed body, never re-assembled.
      # A task with none (a tool row, a round never scheduled) is the
      # kernel's 404 `request_not_sealed`. Browse standing suffices.
      def request = shape(SealedRequest, @dispatch.call("#{path}/request"), "request")

      private

        # Every adjudication door answers `{task}` — the task as it now
        # stands, which for a retry is requeued, for an abandon carries
        # its `failure_resolution`, and for an approval carries its fact.
        def adjudicated(body) = shape(RunTask, body, "task")

        def path
          "/agent_api/v1/workspaces/#{path_segment(@workspace_public_id, "workspace_public_id")}" \
            "/runs/#{path_segment(@run_public_id, "run_public_id")}" \
            "/tasks/#{path_segment(@task_key, "task_key")}"
        end
    end
  end
end
