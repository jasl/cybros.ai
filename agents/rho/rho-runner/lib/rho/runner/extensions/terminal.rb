module Rho
  class Runner
    module Extensions
      module Terminal
        NAME = "rho.terminal".freeze

        def self.register(api)
          executable = api.configuration.fetch("executable", "").to_s
          unless executable.start_with?("/") && File.file?(executable) && File.executable?(executable)
            raise PrerequisiteError, "Terminal needs an executable transport helper; build rho-runner/transport and set executable to its absolute path"
          end

          require "rho/runner/tools/terminal"
          api.register_tool(Tools::Terminal.configured(executable: executable, servers: api.configuration.fetch("ice_servers", [])))
        end
      end
    end
  end
end
