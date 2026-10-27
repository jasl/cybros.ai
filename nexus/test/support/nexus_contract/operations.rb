module Nexus
  module Contract
    class << self
      private

        # Live Rails routes own operation identity. Parameter names are carried
        # verbatim; SDK tests bind these entries to calls through public methods.
        # OAuth ceremonies and Cable are tested by their separate protocol packs.
        def operations
          rows = Rails.application.routes.routes.flat_map do |route|
            path = route.path.spec.to_s.delete_suffix("(.:format)")
            next [] unless path.start_with?("/agent_api/v1/", "/api/v1/")

            path = path.gsub(/:([a-zA-Z_][a-zA-Z_0-9]*)/, '{\1}')
            plane = if path.start_with?("/api/v1/")
              "platform"
            elsif path.start_with?("/agent_api/v1/executor/") || path == "/agent_api/v1/executor"
              "executor"
            else
              "member"
            end
            route.verb.split("|").map do |method|
              id = "#{method} #{path}"
              exclusion = if id == "POST /api/v1/admin/users/{user_public_id}/removal"
                "Typed SDK admin User removal is intentionally excluded"
              end
              {
                "id" => id,
                "plane" => plane,
                "method" => method,
                "path" => path,
                "sdk_supported" => exclusion.nil?,
              }.tap do |entry|
                entry["exclusion"] = exclusion if exclusion
              end
            end
          end

          { "operations" => rows.sort_by { |row| row.fetch("id") } }
        end
    end
  end
end
