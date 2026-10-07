require "rho"
require "rho/runner"
require "json"
require_relative "t3/version"

module Rho
  module T3
    NAME = "rho.t3".freeze
    class Error < Rho::Error; end
    class Uncertain < Error; end
  end
end

require_relative "t3/settings"
require_relative "t3/native_environment"
require_relative "t3/local_server"
require_relative "t3/catalog"
require_relative "t3/bridge"
require_relative "t3/records"
require_relative "t3/projection"
require_relative "t3/session"
require_relative "t3/work"
require_relative "t3/tools"
require_relative "t3/setup"

module Rho
  module T3
    def self.register(api)
      raise Error, "T3 delegation requires rho agent or full mode" unless api.serves?(:agent)

      settings = Settings.parse(api.configuration)
      member_plane = api.host.member_plane
      home = api.host.home
      native = NativeEnvironment.for(home)
      local = LocalServer.new(settings: settings, native: native) if settings.local? && api.host.serving_tools
      api.restart_only if settings.local?
      api.on(:startup) { local.start } if local
      api.on(:shutdown) { local.stop } if local
      api.describe_status do
        issues = settings.issues
        issues << "The local T3 service is not running" if local && !local.running?
        { ready: issues.empty?, issues: issues }
      end
      Setup.register(api, settings: settings, native: native)
      return unless settings.configured?

      factory = lambda do |env|
        Work.new(settings: settings, session: Session.new(member_plane: member_plane), env: env, home: home)
      end
      api.register_tool(Tools.delegate(factory), serves: :agent)
      api.register_tool(Tools.control(factory), serves: :agent)
      nil
    end
  end
end
