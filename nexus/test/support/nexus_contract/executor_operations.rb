module Nexus
  module Contract
    class << self
      private

        # Language-neutral trace fixtures use the producer's projections over
        # sealed result entries. OperationContractTest binds every envelope
        # to the real executor HTTP doors, including replay and pagination.
        def executor_operations
          identities = {
            "run_public_id" => "019f0000-0000-7000-8000-000000000701",
            "task_key" => "program",
            "child_task_key" => "019f0000-0000-7000-8000-000000000702",
            "executor_public_id" => contract_runner.public_id,
          }
          child = identities.fetch("child_task_key")
          record_type = Data.define(:position, :operation_key, :request, :response,
            :observed_position, :observation, :observation_body)
          accepted = record_type.new(position: 1, operation_key: "read",
            request: { "kind" => "tool", "name" => "read_file", "input" => { "path" => "one" } },
            response: { "receipt" => {
              "task_keys" => [child], "result_task_keys" => [child], "steps" => [child],
              "keys" => { "tool-1" => child }, "background" => false,
            } }, observed_position: 2, observation: {}, observation_body: nil)
          refusal = { "code" => "unknown_tool_name", "message" => '"write_file" is not declared for this execution' }
          refused = accepted.with(operation_key: "refused",
            request: { "kind" => "tool", "name" => "write_file", "input" => {} },
            response: { "refusal" => refusal }, observation: { "refusal" => refusal })
          context_type = Data.define(:operation_context) do
            def model_task? = false
          end
          context = Executors::TaskOperations::Context.projection(context_type.new(
            operation_context: {
              "tools" => [{ "type" => "function", "route" => { "kind" => "runner",
                "runner_executor_public_id" => contract_runner.public_id, "tool_name" => "read_file" }, "function" => {
                "name" => "read_file", "parameters" => { "type" => "object" },
              } }],
              "model" => { "model" => "dev/mock-text" },
              "environment" => { "skills" => [], "runner_candidates" => [], "executors" => [{ "environment" => {},
                "runner_executor_public_id" => contract_runner.public_id }],
                "default_runner_executor_public_id" => contract_runner.public_id },
            }
          ))
          outcomes = {
            "false" => { "content" => "read", "structured_content" => false },
            "null" => { "content" => "read", "structured_content" => nil },
            "absent_structured" => { "content" => "read" },
            "absent_output" => {},
          }.transform_values do |request|
            entries = AgentRuns::Parks::ResultContent.call(
              content: request["content"], structured_content: request["structured_content"],
              structured_content_present: request.key?("structured_content")
            ).entries
            observation = accepted.with(
              observation: { "batch" => false, "results" => [{
                "run_public_id" => identities.fetch("run_public_id"), "task_key" => child,
                "status" => "completed", "is_error" => false, "error" => nil,
                "offset" => 0, "length" => entries.length, "output_present" => entries.any?,
                "readable_text" => request["content"],
              }] },
              observation_body: Data.define(:entry_payloads).new(entry_payloads: entries)
            )
            { "commit_request" => request,
              "observation" => { "observation" => Executors::TaskOperations::Trace.observation(observation), "position" => 2 } }
          end
          operation = Executors::TaskOperations::Trace.operation(accepted)
          observation = outcomes.fetch("false").dig("observation", "observation")
          page = ->(trace, position, next_after = nil) {
            { "operations" => { "context" => context, "trace" => trace,
              "position" => position, "next_after" => next_after } }
          }
          {
            "identities" => identities,
            "accepted_operation" => { "operation" => operation },
            "refused_operation" => { "operation" => Executors::TaskOperations::Trace.operation(refused) },
            "refused_observation" => { "observation" => Executors::TaskOperations::Trace.observation(refused), "position" => 2 },
            "waiting_observation" => { "observation" => nil, "position" => 1 },
            "paused_operation" => { "error" => { "code" => "execution_paused", "message" => "Refused: execution_paused" } },
            "outcomes" => outcomes,
            "pages" => {
              "initial" => page.call([], 0), "page_1" => page.call([operation], 2, 1),
              "page_2" => page.call([observation], 2), "complete" => page.call([operation, observation], 2),
            },
            "final" => {
              "commit_request" => { "content" => "complete", "structured_content" => false },
              "response" => operation_final_fixture(identities),
            },
          }
        end

        def operation_final_fixture(identities)
          node = CONTRACT_NODE_TYPE.new(id: 1, node_key: identities.fetch("task_key"),
            task_kind: "tool_task", status: "completed", target_executor_public_id: contract_runner.public_id,
            target_executor: contract_runner, on_failure: "propagate", tool_name: "program",
            addressed_role: "runner", addressed_executor: contract_runner,
            claimed_by_executor_public_id: identities.fetch("executor_public_id"),
            approval_origin: "author", approval_decided_at: Time.utc(2026, 9, 12),
            output_summary: { "resolved" => true }, transcript_visibility: "collapsed",
            created_at: Time.utc(2026, 9, 12), started_at: Time.utc(2026, 9, 12, 0, 0, 1),
            completed_at: Time.utc(2026, 9, 12, 0, 0, 3))
          { "task" => AgentAPI::AgentRunPresenter.task(node, live_server_ids: []) }
        end
    end
  end
end
