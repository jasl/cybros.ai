# A test client inside the paired agent process. It uses only the public
# member SDK and contributes no tool, VM, executor or kernel shortcut.
module CodemodeAuthor
  NAME = "e2e.codemode-author".freeze

  def self.register(api)
    api.register_route("GET", "/e2e/code-context") do |request, ctx|
      ctx.member_plane(request) do |client, _workspace, _about, _body|
        assembled = client.tools.assemble(default_runner_executor_public_id: ctx.runner_selection({}))
        [200, { "tools" => assembled.tool_definitions }]
      end
    end
    api.register_route("POST", "/e2e/standalone-code") do |request, ctx|
      ctx.member_plane(request, body: true) do |client, workspace, _about, body|
        runs = client.workspace(workspace).runs
        created = runs.create(steps: body.fetch("steps"), idempotency_key: body.fetch("idempotency_key"), approval_mode: "bypass",
          default_runner_executor_public_id: ctx.runner_selection(body))
        runs.run(created.run.public_id).start
        [201, { "public_id" => created.run.public_id }]
      end
    end
  end
end
