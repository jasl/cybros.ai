require_relative "packages/tools"

module Rho
  module Extensions
    module Packages
      NAME = "rho.packages".freeze
      USAGE = "extensions list | extensions install DIR | extensions check NAME [VERSION] | extensions activate NAME [VERSION] | extensions disable NAME | extensions rollback NAME".freeze

      def self.register(api)
        if api.serves?(:agent)
          [Read, Manage].each { |tool| api.register_tool(tool.for_home(api.host.home), serves: :agent) }
        end
      end

      def self.command(cli, arguments, options)
        document = case arguments
        in [] | ["list"]
          cli.core.packages
        in ["install", path]
          cli.core.manage_package(action: "install", path: File.expand_path(path))
        in ["check" | "activate" => action, name, *versions] if versions.length <= 1
          fields = { action: action, name: name, version: versions.first }
          fields[:configuration] = JSON.parse(File.read(options[:configuration])).to_h if options[:configuration]
          cli.core.manage_package(**fields)
        in ["disable" | "rollback" => action, name]
          cli.core.manage_package(action: action, name: name)
        else
          raise Rho::Error, "Use rho #{USAGE}"
        end
        cli.out.puts JSON.pretty_generate(document)
        raise Rho::Error, "Extension package checks failed" if document["passed"] == false

        document
      rescue JSON::ParserError, NoMethodError, TypeError
        raise Rho::Error, "--configuration takes a JSON object file"
      rescue Errno::ENOENT, Errno::EACCES => error
        raise Rho::Error, error.message
      end
    end
  end
end
