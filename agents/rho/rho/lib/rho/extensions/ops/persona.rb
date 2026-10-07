module Rho
  module Extensions
    module Ops
      module Persona
        USAGE = "persona show | persona set FILE | persona reset".freeze
        CONTENT_BYTES = 64 * 1024

        def self.register(api)
          api.register_command("persona", usage: USAGE,
            description: "Read, replace or reset your Nexus persona; use set - to read standard input",
            options: { json: { type: :boolean, default: false, desc: "Print JSON" } }, &method(:command))
        end

        def self.command(cli, arguments, options, input: $stdin)
          case arguments
          in ["show"] | []
            document = cli.core.persona
            cli.out.puts(options[:json] ? JSON.pretty_generate(document) : document.fetch(:content))
            document
          in ["set", path]
            content = path == "-" ? input.read(CONTENT_BYTES + 1).to_s : File.read(path, CONTENT_BYTES + 1, encoding: "UTF-8")
            raise Rho::Error, "A persona must fit within 64 KiB" if content.bytesize > CONTENT_BYTES

            content.force_encoding(Encoding::UTF_8)
            raise Rho::Error, "A persona must contain UTF-8 text" unless content.valid_encoding?

            document = cli.core.write_persona(content)
            cli.out.puts(options[:json] ? JSON.pretty_generate(document) : "Persona saved in Nexus; future personal turns will read it.")
            document
          in ["reset"]
            cli.core.reset_persona
            cli.out.puts(options[:json] ? JSON.generate(reset: true) : "Persona reset.")
            nil
          else
            raise Rho::Error, "Use rho #{USAGE}"
          end
        rescue Errno::ENOENT, Errno::EACCES => error
          raise Rho::Error, error.message
        rescue CybrosAgent::Api::NotFound => error
          raise unless error.code == "prompt_document_not_found" && arguments.first != "set"

          cli.out.puts(options[:json] ? JSON.generate(nil) : "No persona is set.")
          nil
        end
      end
    end
  end
end
