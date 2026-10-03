# THE HANDOFF on the wire, shared by the two host doors: PUT `…/runner`,
# body `{runner: {executor_public_id}}`, the service's accepted answer
# rendered as the host document (the same id is a plain 200 — idempotent by
# value, no receipt); 404 `runner_not_found`; 409 `runner_not_eligible`
# with the reason as the message — neither is a family code, since
# `runner_not_eligible` is 422 at the create doors; 403 `not_authorized`
# through the plane's map.
module AgentAPI::V1::Workspaces::RunnerBinding
  extend ActiveSupport::Concern

  private

    def bind_runner(host)
      fields = params.expect(runner: [:executor_public_id])
      result = ::Executors::Handoff.call(::Executors::Handoff::Command.new(
        host: host, executor_public_id: fields[:executor_public_id].to_s, acting_user: acting_user
      ))

      case result.outcome
      when :accepted
        render_bound_host(result.value.host)
      when :runner_not_found
        render_error(:runner_not_found, "No runner this host may bind is known by that id", status: :not_found)
      when :runner_not_eligible
        render_error(:runner_not_eligible, result.detail, status: :conflict)
      else
        render_refusal(result.outcome)
      end
    end
end
