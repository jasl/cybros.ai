require "json"
require "mini_racer"
require "securerandom"
require "rho/runner"
require_relative "codemode/version"
require_relative "codemode/runtime"
require_relative "codemode/authoring"
require_relative "codemode/code"

module Rho
  # JavaScript authoring and live VM state belong here. The claim-scoped
  # bridge reaches Nexus for task acceptance, durable observations and scheduling.
  module Codemode
    NAME = "rho.codemode".freeze

    def self.register(api)
      %i[agent runner].each do |address|
        api.register_tool(Code, serves: address) if api.serves?(address)
      end
    end
  end
end
