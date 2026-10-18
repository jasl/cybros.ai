module Runs
  module ScheduleTool
    # Schedule commands and their tool result commit under the parent host and
    # source Run. A repeated job therefore observes the settled task before it
    # can create another schedule or apply a second optimistic edit.
    class Run
      ACTION_FIELDS = {
        "list" => [], "show" => %w[job_id], "history" => %w[job_id],
        "create" => %w[prompt rule], "update" => %w[job_id expected_lock_version],
        "pause" => %w[job_id], "resume" => %w[job_id], "cancel" => %w[job_id],
      }.freeze

      def self.call(node:) = new(node).call

      def initialize(node)
        @node = node
        @run = node.run
        @conversation = @run.conversation
        @actor = @run.answering_user
        @input = node.tool_input
      end

      def call
        return :not_running unless @node.status == "running"
        return refuse(:conversation_required) unless @conversation
        return refuse(:not_authorized) unless @conversation.readable_by?(@actor)

        action = @input["action"].to_s
        reading = Nexus::ToolRegistry.resolve(@node.tool_name) == "nexus.schedules.read"
        allowed = reading ? %w[list show history] : %w[create update pause resume cancel]
        return refuse(:invalid_action) unless allowed.include?(action)
        missing = ACTION_FIELDS.fetch(action) - @input.keys
        return refuse(:missing_fields, missing.join(", ")) unless missing.empty?

        reading ? read(action) : manage(action)
      end

      private

        def read(action)
          if action == "list"
            rows, after = page(@conversation.schedules.including_context)
            return refuse(:invalid_after) unless rows

            records = ::Schedules::Projection.many(rows, by: @actor, workspace: @run.workspace)
            return settle_read({ schedules: records.map { |row| row.except(:agent_configuration) }, next_after: after })
          end

          job = find_job
          return refuse(:not_found) unless job
          return settle_read(present(job)) if action == "show"

          visible = Conversation.visible_to(@actor, workspace: @run.workspace).where(schedule_id: job.id)
          rows, after = page(visible)
          return refuse(:invalid_after) unless rows

          projected = ::Schedules::ExecutionProjection.call(rows.map(&:id))
          settle_read({ executions: rows.map { |child| projected.fetch(child.id) }, next_after: after,
            last_cursor: rows.last&.public_id || @input["after"] })
        end

        def page(scope)
          after = @input["after"]
          return [nil, nil] if after && !Input.uuid_shaped?(after)

          limit = (Integer(@input["limit"], exception: false) || 30).clamp(1, 50)
          scope = scope.where("public_id > ?", after) if after
          rows = scope.order(:public_id).limit(limit + 1).to_a
          [rows.first(limit), (rows[limit - 1].public_id if rows.length > limit)]
        end

        def manage(action)
          return create if action == "create"

          job = find_job
          return refuse(:not_found) unless job

          manager = ::Schedules::Manage.new(job)
          command = action.to_sym unless action == "update"
          manager.synchronize(command: command) do
            executing do
              outcome = if command
                manager.transition_locked(command, by: @actor)
              else
                version = Integer(@input["expected_lock_version"], exception: false)
                next refuse(:invalid_lock_version) unless version && version >= 0

                manager.revise_locked(@input.slice("name", "prompt", "rule"), by: @actor,
                  expected_lock_version: version)
              end
              settle_outcome(outcome)
            end
          end
        end

        def create
          # MCP start locks this Agent before the same Run. Pin the Schedule's
          # creator/answerer FK first; inserting under the Run must not reverse it.
          @actor.with_lock("FOR KEY SHARE") do
            @conversation.with_lock do
              executing do
                intent = ::Schedules::Intent.from_task(@node)
                next settle_outcome(intent) unless intent.accepted?

                result = ::Schedules::Create.create_locked(conversation: @conversation, creating_user: @actor,
                  attributes: intent.value.merge(@input.slice("name", "prompt", "rule")))
                settle_outcome(result)
              end
            end
          end
        end

        # The host precedes this Run. Stop and duplicate jobs arbitrate here;
        # no mutation can escape after its tool was canceled or settled.
        def executing
          @run.with_lock do
            @node.reload
            next :idle if @run.terminal? || @node.status != "running"
            next Parks::Settle.call(node: @node, timeout: true).outcome if @node.deadline_passed?

            yield
          end
        end

        def find_job
          public_id = @input["job_id"]
          @conversation.schedules.find_by(public_id: public_id) if Input.uuid_shaped?(public_id)
        end

        def present(job) = ::Schedules::Projection.full(job, by: @actor).except(:agent_configuration)

        def settle_read(value)
          outcome = settle(value)
          if outcome == :result_too_large
            refuse(:result_too_large, "Use a smaller list limit or read the full saved record through the Schedules API.")
          else
            outcome
          end
        end

        def settle_outcome(result)
          if result.accepted?
            record = present(result.value)
            outcome = settle(record)
            # The saved prompt can fit its own bound but overflow when encoded
            # again inside a text result. Commit a small durable receipt with
            # the mutation; the full instruction remains on the Schedule door.
            if outcome == :result_too_large
              settle(record.slice(:public_id, :status, :lock_version, :next_run_at))
            else
              outcome
            end
          elsif result.invalid?
            refuse(:invalid_schedule, result.errors.full_messages.join("; "))
          else
            refuse(result.outcome)
          end
        end

        def refuse(code, detail = nil)
          KernelTool.settle(@node, [code, detail].compact.join(": "), title: "schedule refused", is_error: true)
        end

        def settle(value)
          KernelTool.settle(@node, value.to_json, title: "scheduled work")
        end
    end
  end
end
