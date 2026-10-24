module Rho
  module Env
    module Extensions
      module Terminal
        NAME = "rho.terminal".freeze

        def self.register(api)
          executable = api.configuration.fetch("executable", "").to_s
          unless executable.start_with?("/") && File.file?(executable) && File.executable?(executable)
            raise PrerequisiteError, "Terminal needs an executable transport helper; build rho-env/transport and set executable to its absolute path"
          end

          require "rho/env/tools/terminal"
          api.register_tool(Tools::Terminal.configured(executable: executable, servers: api.configuration.fetch("ice_servers", [])))
        end
      end
    end
  end
end
