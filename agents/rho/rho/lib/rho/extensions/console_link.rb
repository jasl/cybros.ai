module Rho
  module Extensions
    module ConsoleLink
      NAME = "rho.console_link".freeze

      def self.register(api)
        api.register_route("GET", "/console") do |_request, ctx|
          if ctx.page?
            [200, { url: ctx.config.public_url || ctx.endpoint }]
          else
            Daemon::Refusal.new(status: 409, code: "page_not_served", message: "This daemon serves no console page")
          end
        end
        api.register_command("console", description: "Open rho and sign in with Nexus",
          options: { open: { type: :boolean, default: false, desc: "Launch a browser at the page" } },
          &Commands.method(:console))
      end

      module Commands
        def self.console(cli, _args, options)
          daemon = cli.core.require_daemon
          response = cli.core.get(daemon, "/console")
          document = cli.core.parse(response)
          raise Rho::Error, cli.core.failure_message(document) unless response.code.to_i == 200

          url = document.fetch("url")
          cli.out.puts "console: #{url}"
          cli.out.puts "Sign in with Nexus to open this rho."
          Rho::Cli::Browser.launch(url, out: cli.out) if options[:open]
          document
        end
      end
    end
  end
end
