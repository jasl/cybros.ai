module Rho
  class Runner
    module Tools
      # Explicit user-facing artifact publication uses the existing capture
      # upload at TaskRun commit. A path mentioned in prose publishes nothing.
      class FilePublish
        NAME = "file_publish".freeze
        DESCRIPTION = "Publish an existing local file as a downloadable artifact for the user. " \
          "Use after creating a report, PDF, spreadsheet, document, image, code file or archive. " \
          "The result's resource link confirms publication; a local path alone is not a download link.".freeze
        EFFECT_PROFILE = Read::EFFECT_PROFILE
        SCHEMA = FilesBytes::SCHEMA

        def initialize(env:)
          @env = env
        end

        def call(args)
          ExecutionContext.current&.raise_if_cancelled!
          case Files.locate(root: @env.root, path: args.fetch("path"))
          in Files::Refusal => refusal
            Result.error(refusal.message)
          in Files::Located => file
            Result.ok("File selected for publication: #{File.basename(file.path)} (#{file.size} bytes). " \
              "Use the resource link returned with this result.", files: [file.path], files_required: true)
          end
        end
      end
    end
  end
end
