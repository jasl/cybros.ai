module Rho
  module Extensions
    module Setup
      # The deployment helper owns this file. It reports first-account facts;
      # the ordinary device flow and credential planes still own connection.
      module Installation
        Projection = Data.define(:nexus_ready, :setup_url, :error) do
          def self.from_h(document)
            ready = document.fetch("nexus_ready")
            unless [true, false].include?(ready)
              raise StateError, "installation readiness must be a boolean"
            end

            new(nexus_ready: ready, setup_url: ready ? nil : setup_link(document["setup_url"]),
              error: document["error"]&.to_s)
          end

          def self.setup_link(value)
            return nil if value.nil?

            uri = URI.parse(value.to_s)
            unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
              raise StateError, "installation setup link must use http(s)"
            end
            uri.to_s
          rescue URI::InvalidURIError
            raise StateError, "installation setup link is invalid", cause: nil
          end
        end

        def self.read(ctx)
          path = ctx.config.installation_file
          document = { enabled: !path.nil?, password_required: false, nexus_ready: nil, setup_url: nil, error: nil }
          if path
            # Only a saved password counts. The generated environment seed
            # keeps the initial daemon locked until a console link is redeemed.
            document[:password_required] = Config.read(ctx.home.settings_path)["access_passphrase"].to_s.empty?
            source = StateFile.new(path).read
            if source
              projection = Projection.from_h(source)
              document[:nexus_ready] = projection.nexus_ready
              document[:setup_url] = projection.setup_url unless document[:password_required]
              document[:error] = projection.error
            end
          end
          [200, document]
        rescue StateError, ConfigurationError, KeyError, SystemCallError
          Rho::Daemon::Refusal.new(status: 503, code: "installation_unavailable",
            message: "Installation status is unavailable. Run ./cybros up from the installation directory to retry.")
        end
      end
    end
  end
end
