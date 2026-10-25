require "ipaddr"

module Rho
  module Env
    module Extensions
      module Terminal
        NAME = "rho.terminal".freeze
        WEBUI_ROOT = File.expand_path("../../../../webui/terminal", __dir__).freeze
        BUNDLED_EXECUTABLE = File.expand_path("../../../../transport/rho-webrtc", __dir__).freeze

        def self.register(api)
          executable = api.configuration.fetch("executable", "").to_s
          executable = BUNDLED_EXECUTABLE if executable.empty?
          unless executable.start_with?("/") && File.file?(executable) && File.executable?(executable)
            raise PrerequisiteError, "Terminal needs an executable transport helper; build rho-env/transport and set executable to its absolute path"
          end

          require "rho/env/tools/terminal"
          network = WebrtcTransport::Network.new(
            advertised_ip: api.configuration.fetch("advertised_ip", ""),
            udp_port_min: api.configuration.fetch("udp_port_min", 49160),
            udp_port_max: api.configuration.fetch("udp_port_max", 49200)
          )
          unless network.advertised_ip.empty?
            if network.advertised_ip.include?("/")
              raise PrerequisiteError, "Terminal advertised address must be one IP address, not a subnet"
            end
            IPAddr.new(network.advertised_ip)
          end
          if network.udp_port_min > network.udp_port_max
            raise PrerequisiteError, "Terminal UDP port minimum must not exceed its maximum"
          end
          api.register_tool(Tools::Terminal.configured(executable: executable,
            servers: api.configuration.fetch("ice_servers", []), network: network))
          api.register_webui_module(root: WEBUI_ROOT)
        rescue IPAddr::InvalidAddressError
          raise PrerequisiteError, "Terminal advertised address must be an IP address"
        end
      end
    end
  end
end
