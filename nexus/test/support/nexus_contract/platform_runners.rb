module Nexus
  module Contract
    class << self
      private

        def platform_runners
          human = Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000010")
          runner_type = Data.define(:id, :public_id, :executor_kind, :display_name, :status, :manager,
            :assignment_scope, :presence_connection_id, :presence_server_id,
            :last_seen_at, :connected_at, :created_at, :services) do
            def service_roles = services.roles
            def eligible_for?(_principal, readiness:) = true
          end
          measured_at = Time.utc(2026, 10, 16)
          runner = runner_type.new(
            id: 1, public_id: "01900000-0000-7000-8000-000000000021", executor_kind: "runner",
            display_name: "Fixture runner", status: "active", manager: human,
            assignment_scope: "user_private",
            presence_connection_id: nil, presence_server_id: nil,
            last_seen_at: measured_at, connected_at: nil, created_at: measured_at - 1.day,
            services: Executor::Services.new(runner: { "tools" => [{ "name" => "read", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
              "description" => "Read a file.", "input_schema" => { "type" => "object" } }],
            "documents" => [{ "name" => "project", "description" => "Project instructions." }],
            "environment" => { "root" => "/srv/work" } })
          )
          context = { principal: human, readiness: { runner.id => :ready }, live_server_ids: [] }
          {
            "valid_runners_fixture" => {
              "runners" => [API::RunnerPresenter.basic(runner, **context)],
              "pagination" => { "next_after" => nil }, "measured_at" => measured_at,
            },
            "valid_runner_fixture" => {
              "runner" => API::RunnerPresenter.full(runner, **context), "measured_at" => measured_at,
            },
            "filters" => %w[kind status],
            "kinds" => Executor::MACHINE_KINDS,
            "statuses" => Executor.statuses.keys.sort,
          }
        end
    end
  end
end
