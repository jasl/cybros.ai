module NexusDoubles
  class FakeAgentApi
    # THE KERNEL'S OWN CEREMONY ON EVERY TASK ROW: a scripted detail names
    # the fields its case is about, and the double answers a row the
    # kernel could have sent — the task's lifetime and wake are on every
    # row the presenter writes, and the SDK's shape requires both, so a
    # fixture without them made a reader that swallows a parse error go
    # silent instead of failing (rho-dev's `follow` todo block, 2026-09-22).
    TASK_ROW_CEREMONY = { "lifetime" => "conversation", "wake" => "auto" }.freeze

    # THE LOOP DOORS THE REPAIR VERBS DRIVE: read a scripted trace, answer
    # the three adjudication verbs, and tombstone on DELETE.
    def agent_loop_response(method, path, credential, body = nil)
      return nil unless credential == MEMBER_TOKEN

      if @loop_list && method == :get &&
          path.match?(%r{\A/agent_api/v1/workspaces/[^/]+/agent_loops\z})
        return respond(200, { "agent_loops" => @loop_list,
                              "pagination" => { "next_after" => nil } })
      end

      if method == :post && path.match?(%r{\A/agent_api/v1/workspaces/[^/]+/agent_loops\z})
        @loop_creates << body
        tasks = step_rows(Array(body.dig("agent_loop", "steps")))
        @minted_tasks["al-#{@loop_creates.length}"] = tasks
        @runner_bindings["al-#{@loop_creates.length}"] = body.dig("agent_loop", "runner_executor_public_id")
        return respond(201, { "agent_loop" => minted_loop("al-#{@loop_creates.length}", "queued", tasks),
                              "receipt" => { "accepted_task_keys" => tasks.map { |task| task["key"] },
                                             "steps" => tasks.map { |task| task["key"] },
                                             "deliverable_task_key" => tasks.last&.fetch("key"),
                                             "revision" => 1, "resolution_tokens" => {}, "replayed" => false } })
      end

      loop_path = %r{\A/agent_api/v1/workspaces/[^/]+/agent_loops/[^/]+}
      return nil unless path.match?(loop_path)

      if method == :put && (bound = path[%r{/agent_loops/([^/]+)/runner\z}, 1])
        return handoff_response(bound, body) do
          respond(200, { "agent_loop" => minted_loop(bound, "running", @minted_tasks.fetch(bound, [])) })
        end
      end

      if method == :post && (started = path[%r{/agent_loops/([^/]+)/start\z}, 1])
        return respond(200, { "agent_loop" => minted_loop(started, "running", @minted_tasks.fetch(started, [])) })
      end

      if @transcript && method == :get && path.end_with?("/transcript")
        return respond(200, @transcript)
      end
      if @graph && method == :get && path.end_with?("/graph")
        return respond(200, @graph)
      end
      if @phases && method == :get && path.end_with?("/phases")
        return respond(200, @phases)
      end
      # Before the task read: its key pattern would take `request` for a key.
      if @task_request && method == :get && path.match?(%r{/tasks/[^/]+/request\z})
        return @task_request.is_a?(CybrosAgent::Response) ? @task_request : respond(200, @task_request)
      end
      if @task_detail && method == :get && (key = path[%r{/tasks/([^/]+)\z}, 1])
        return respond(200, { "task" => TASK_ROW_CEREMONY.merge(@task_detail).merge("key" => key) })
      end

      if method == :post && path.end_with?("/inputs")
        @loop_inputs << body
        fields = body.fetch("input")
        return respond(202, { "input" => {
          "public_id" => "in-#{@loop_inputs.length}", "queue_position" => @loop_inputs.length - 1,
          "state" => fields.fetch("delivery_mode", "queue") == "steer" ? "steering" : "pending",
          "kind" => fields.fetch("kind", "message"), "role" => "user",
          "delivery_mode" => fields.fetch("delivery_mode", "queue"), "text" => fields["text"],
          "origin" => "person", "lock_version" => 0, "created_at" => "2026-09-05T00:00:00Z",
          # A loop-host row answers as the loop's creator.
          "answering_user_public_id" => @user_public_id, "speaker" => NexusDoubles.speaker_row(@user_public_id),
        } })
      end
      if method == :post && path.end_with?("/stop")
        return respond(200, { "agent_loop" => (@trace || minted_loop(path[%r{/agent_loops/([^/]+)/stop\z}, 1], "running", []))
          .merge("status" => "canceling") })
      end
      if method == :post && (resolved = path[%r{/tasks/([^/]+)/resolution\z}, 1])
        @resolutions << body
        return respond(200, { "task" => { "key" => resolved, "kind" => "await_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
                                           "on_failure" => "halt", "visibility" => "hidden",
                                           "created_at" => "2026-09-04T00:00:00Z" } })
      end

      if method == :post && path.end_with?("/tasks")
        @appends << body
        return @append if @append.is_a?(CybrosAgent::Response)

        keys = step_rows(Array(body && body["steps"])).map { |row| row["key"] }
        return respond(201, { "receipt" => { "accepted_task_keys" => keys, "steps" => keys,
                                             "deliverable_task_key" => keys.last, "revision" => 2,
                                             "resolution_tokens" => {}, "replayed" => false } })
      end

      if (verb = path[%r{/tasks/([^/]+)/(retry|abandon|cancel|compact|approve|deny)\z}, 2])
        key = path[%r{/tasks/([^/]+)/}, 1]
        @adjudications << [verb, key, body]
        return @adjudication if @adjudication.is_a?(CybrosAgent::Response)

        # The task projection the doors really answer: a `kind` is not
        # optional, and a projection missing one refuses on the way in.
        task = { "key" => key, "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto",
                 "on_failure" => "halt", "visibility" => "visible",
                 "created_at" => "2026-09-04T00:00:00Z" }
        if verb == "compact"
          return respond(202, { "task" => task.merge("status" => "waiting"),
                                "summary_task_key" => "k1" })
        end

        # THE APPROVAL VERBS: a held tool row released to its
        # runner with the stage's fact — the approver's KIND as origin, the
        # daemon's member bearer resolving to the Agent Profile user — or
        # failed `approval_denied` with the reason as the detail.
        if %w[approve deny].include?(verb)
          fact = { "origin" => "agent", "decided_by" => @user_public_id, "decided_at" => "2026-09-08T12:00:00Z" }
          held = task.merge("kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "tool_name" => "bash", "on_failure" => "absorb", "approval" => fact)
          return respond(200, { "task" => held.merge("status" => "dispatched") }) if verb == "approve"

          return respond(200, { "task" => held.merge("status" => "failed",
            "error" => { "key" => "approval_denied", "detail" => body && body["reason"] }.compact) })
        end

        settled, resolution =
          case verb
          when "abandon" then %w[failed abandoned]
          when "cancel" then %w[canceled canceled]
          else ["waiting", nil]
          end
        return respond(200, { "task" => task.merge("status" => settled,
                                                   "failure_resolution" => resolution).compact })
      end

      return respond(204, nil) if method == :delete
      return respond(200, { "agent_loop" => @trace }) if method == :get && @trace

      nil
    end

    private

      # The step tree flattened to the rows the trace would show: one per
      # placed step, in written order, a group's members in theirs.
      def step_rows(steps)
        steps.flat_map do |step|
          case step
          when Array then step_rows(step)
          else
            if step.key?("parallel")
              step_rows(step["parallel"])
            else
              verb, fields = step.first
              [{ "key" => fields["key"], "kind" => { "model" => "model_task", "tool" => "tool_task",
                                                     "ask" => "await_task" }.fetch(verb) }]
            end
          end
        end
      end

      def minted_loop(public_id, status, tasks)
        { "public_id" => public_id, "status" => status, "deliverable_task_key" => "work",
          "tasks" => tasks.map do |task|
            { "key" => task["key"], "kind" => task["kind"], "lifetime" => "conversation", "wake" => "auto", "status" => "queued",
              "on_failure" => "halt", "visibility" => "visible", "created_at" => "2026-09-05T00:00:00Z" }
          end,
          "created_at" => "2026-09-05T00:00:00Z", "updated_at" => "2026-09-05T00:00:00Z",
          "runner" => runner_binding(public_id) }.compact
      end
  end
end
