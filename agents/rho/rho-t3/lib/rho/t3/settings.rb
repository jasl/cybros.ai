require "uri"

module Rho
  module T3
    # The saved configuration, read once at registration. The bearer is the
    # saved write-only `token` and nothing else: `rho t3 token` and the page
    # save it, status says only whether one is saved.
    Settings = Data.define(:server, :listen_port, :url, :token, :project_id, :default_agent, :workspace) do
      def self.parse(raw)
        raw = raw.to_h.transform_keys(&:to_s)
        server = raw.fetch("server", "host").to_s
        case server
        when "local"
          port = Integer(raw.fetch("listen_port", 3773).to_s, 10)
          raise Error, "T3 listen_port must be between 1 and 65535" unless (1..65_535).cover?(port)

          url = "http://127.0.0.1:#{port}"
        when "host"
          port = nil
          url = raw.fetch("url", "").to_s.strip.delete_suffix("/")
          unless url.empty?
            origin = URI.parse(url)
            unless %w[http https].include?(origin.scheme) && origin.host && !origin.userinfo && !origin.query && !origin.fragment && ["", "/"].include?(origin.path)
              raise Error, "T3 url must be an HTTP service origin without credentials, path, query or fragment"
            end
          end
        else
          raise Error, "T3 server must select host or local"
        end
        token = raw["token"].to_s.strip
        project = raw.fetch("project_id", "").to_s.strip
        preferred = raw["default_agent"].to_s.strip

        workspace = raw.fetch("workspace", { "type" => "root" }).to_h.transform_keys(&:to_s)
        case workspace.fetch("type")
        when "root" then nil
        when "existing_worktree" then workspace.fetch("worktreePath")
        when "worktree" then workspace.fetch("baseRef")
        else raise Error, "T3 workspace must select root, existing_worktree or worktree"
        end
        new(server: server, listen_port: port, url: url, token: token, project_id: project,
          default_agent: preferred.empty? ? nil : preferred, workspace: workspace)
      rescue URI::InvalidURIError, KeyError, TypeError, NoMethodError, ArgumentError
        raise Error, "T3 configuration is incomplete or malformed", cause: nil
      end

      def local? = server == "local"
      def configured? = issues.empty?
      # What status says of the bearer: that one is saved, or not — never the bearer.
      def bearer = token.empty? ? "none" : "saved"

      def issues
        messages = []
        messages << "Set the host T3 service URL" if url.empty?
        messages << "Save the T3 bearer with rho t3 token" if token.empty?
        messages << "Select a T3 project with rho t3 project or rho t3 create" if project_id.empty?
        messages
      end

      def require_connection
        raise Error, "Set the host T3 service URL first" if url.empty?
        raise Error, "The T3 bearer is not saved" if token.empty?
      end

      def environment
        { "url" => url, "projectId" => project_id,
          "workspaceStrategy" => workspace, "runtimeMode" => "approval-required", "interactionMode" => "default" }
      end
    end
  end
end
