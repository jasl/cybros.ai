require "rho/runner"
require "reverse_markdown"
require_relative "web-tools/version"
require_relative "web-tools/client"
require_relative "web-tools/render"
require_relative "web-tools/tools/fetch"
require_relative "web-tools/commands"

module Rho
  # A WEB READER, AS AN EXTENSION. One tool, `web_fetch {url}`, that GETs a public http(s) URL
  # through httpx with its SSRF filter and same-site redirects under the
  # SDK's one deadline, renders HTML to markdown, answers the head under
  # the runner's truncation caps with bash's own spill footer and pages
  # the rest through `read` — announced `read_only` on the OPEN world,
  # parked under `ask` by the mode's own word, refused for private hosts
  # unless one setting lifts loopback and RFC 1918. One verb beside it.
  #
  # WHY A GEM and not a module in rho-runner: nokogiri and reverse_markdown
  # arrive on every rho install either way (rho's Gemfile carries every
  # extension gem); what the gem buys is the loader's doctrine — `rho/web-tools`
  # registers only when the plugin is enabled — the standalone
  # `rho-runner` gem staying free of an HTML parser, and a separate hosting boundary: a tools-provider process later hosts the same client
  # and render behind the SDK's executor door with the adapter's `ToolEnv`
  # lines changed, not the client or the render.
  #
  # Each registered tool class captures its settings and logger. Replacement
  # contributions cannot change the policy of an already accepted call. The CLI
  # uses the current module settings. Markdown configuration is process-wide and
  # constant; each fetch opens and closes its own HTTP session.
  module WebTools
    NAME = "rho.web_tools".freeze
    SETTINGS_KEYS = %w[allow_private_network].freeze

    class << self
      attr_reader :log, :settings

      # For a test: the judged table as `register` would set it.
      def settings=(table)
        @settings = judge(table)
      end

      def allow_private_network? = settings.fetch("allow_private_network")

      # For tests: forget the settings and the log.
      def reset!
        @settings = nil
        @log = nil
      end

      def register(api)
        @log = api.log
        @settings = judge(api.configuration)
        configure_markdown!
        api.register_tool(Tools::Fetch.configured(settings: @settings, log: @log))
        api.register_command("web", usage: Commands::USAGE, description: Commands::DESCRIPTION,
          options: Commands::OPTIONS) do |cli, args, options|
          Commands.run(cli, args, options)
        end
      end

      # The settings grammar, five lines: one key, one boolean.
      def judge(table)
        table ||= {}
        table.each_key do |key|
          next if SETTINGS_KEYS.include?(key.to_s)

          raise Rho::Runner::Extensions::RegistrationError,
            "settings.json \"plugins.rho.web_tools.configuration\": unknown key #{key.to_s.inspect}; the keys are #{SETTINGS_KEYS.join(", ")}"
        end
        value = table.fetch("allow_private_network", false)
        unless [true, false].include?(value)
          raise Rho::Runner::Extensions::RegistrationError,
            "settings.json \"plugins.rho.web_tools.configuration\": allow_private_network must be true or false, not #{value.inspect}"
        end

        { "allow_private_network" => value }.freeze
      end

      # ONCE, and idempotent: unknown tags pass their text through (a
      # custom element is prose, not a hole), GitHub-flavoured fences and
      # tables for the model.
      def configure_markdown!
        ReverseMarkdown.config do |config|
          config.unknown_tags = :bypass
          config.github_flavored = true
        end
      end
    end
  end
end
