module Rho
  module T3
    # The adopted protocol-2 payloads; responses remain native JSON.
    module RpcSchema
      def self.object(properties, required: properties.keys)
        { "type" => "object", "properties" => properties, "required" => required }
      end

      STRING = { "type" => "string" }.freeze
      ARRAY = { "type" => "array" }.freeze
      MODEL = object({ "instanceId" => STRING, "model" => STRING }).freeze
      WORKSPACE = { "oneOf" => [
        object({ "type" => { "const" => "root" }, "branch" => STRING }, required: %w[type]),
        object({ "type" => { "const" => "existing_worktree" }, "worktreePath" => STRING, "branch" => STRING }, required: %w[type worktreePath]),
        object({ "type" => { "const" => "worktree" }, "baseRef" => STRING, "branch" => STRING, "startFromOrigin" => { "type" => "boolean" } }, required: %w[type baseRef]),
      ] }.freeze
      COMMAND = { "oneOf" => [
        object({ "type" => { "const" => "message.dispatch" }, "commandId" => STRING, "threadId" => STRING, "messageId" => STRING,
          "createdBy" => { "const" => "agent" }, "creationSource" => { "const" => "server" }, "text" => STRING, "attachments" => ARRAY,
          "dispatchMode" => { "oneOf" => [object({ "type" => { "const" => "start_immediately" } }),
            object({ "type" => { "const" => "steer_active" }, "targetRunId" => STRING })] } }),
        object({ "type" => { "const" => "runtime-request.respond" }, "commandId" => STRING, "threadId" => STRING, "requestId" => STRING,
          "decision" => { "enum" => %w[accept decline] }, "answers" => { "type" => "object" } }, required: %w[type commandId threadId requestId]),
        object({ "type" => { "const" => "run.interrupt" }, "commandId" => STRING, "threadId" => STRING, "runId" => STRING,
          "holdQueue" => { "const" => true }, "reason" => STRING }),
      ] }.freeze
      METHODS = {
        "server.getConfig" => object({}),
        "orchestration.launchThread" => object({ "commandId" => STRING, "threadId" => STRING, "projectId" => STRING, "title" => STRING,
          "modelSelection" => MODEL, "runtimeMode" => { "const" => "approval-required" }, "interactionMode" => { "const" => "default" },
          "workspaceStrategy" => WORKSPACE, "initialMessage" => object({ "messageId" => STRING, "text" => STRING, "attachments" => ARRAY }) }),
        "orchestration.getThreadProjection" => object({ "threadId" => STRING }),
        "orchestration.dispatchCommand" => COMMAND,
        "orchestration.getFullThreadDiff" => object({ "threadId" => STRING, "toTurnCount" => { "type" => "number" }, "ignoreWhitespace" => { "type" => "boolean" } }, required: %w[threadId toTurnCount]),
        "orchestration.getTurnItem" => object({ "threadId" => STRING, "itemId" => STRING }),
      }.transform_values { |schema| Rho::Runner::InputSchema.compile(schema) }.freeze

      def self.validate!(method, params)
        validator = METHODS.fetch(method) { raise Error, "Unsupported T3 RPC method" }
        raise Error, "Invalid T3 RPC payload" if Rho::Runner::InputSchema.refusal(validator, params)
      end
    end
  end
end
