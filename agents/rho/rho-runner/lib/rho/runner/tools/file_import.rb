require "tempfile"

module Rho
  class Runner
    module Tools
      # Local working material reconstructed from a Nexus input attachment.
      # Nexus remains the durable owner; parsing belongs to the workspace tools.
      class FileImport
        NAME = "file_import".freeze
        DESCRIPTION = "Download a conversation attachment into this runner's working files. " \
          "Pass its nexus://uploads/... reference or upload UUID. Then use read for text, images or native PDF input. " \
          "Use bash and workspace-tools to parse PDFs when native input is unavailable, " \
          "or to handle Office documents, spreadsheets and archives. " \
          "This does not parse the file.".freeze
        EFFECT_PROFILE = Read::EFFECT_PROFILE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => { "upload" => { "type" => "string", "description" => "Attachment reference or upload UUID" } },
          "required" => ["upload"],
        })
        UPLOAD_ID = /\A(?:nexus:\/\/uploads\/)?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/i
        private_constant :UPLOAD_ID

        def initialize(env:)
          @env = env
        end

        def call(args)
          match = UPLOAD_ID.match(args.fetch("upload"))
          return Result.error("Expected a Nexus attachment reference or upload UUID") unless match

          context = ExecutionContext.current
          return Result.error("Attachment import requires an active executor claim") unless context&.attachments

          context.raise_if_cancelled!
          public_id = match[1].downcase
          directory = @env.ensure_artifacts_dir!
          Tempfile.create(["attachment-", ".part"], directory, binmode: true) do |io|
            upload = context.attachments.read(public_id, io)
            context.raise_if_cancelled!
            io.flush
            return Result.error("Attachment download was incomplete") unless io.size == upload.byte_size

            filename = File.basename(upload.filename).gsub(/[^\p{Alnum}._-]/, "_")
            filename = "attachment" if filename.empty? || %w[. ..].include?(filename)
            extension = File.extname(filename)
            basename = File.basename(filename, extension).chars.take(40).join
            path = File.join(directory, "#{public_id}-#{basename}#{extension.chars.take(12).join}")
            File.rename(io.path, path)
            Result.ok("Imported #{upload.filename} (#{upload.content_type}, #{upload.byte_size} bytes) to #{path}",
              { "path" => path, "upload_public_id" => public_id, "filename" => upload.filename,
                "content_type" => upload.content_type, "byte_size" => upload.byte_size })
          end
        rescue CybrosAgent::Error, SystemCallError, IOError => error
          Result.error("Attachment import failed: #{error.message}")
        end
      end
    end
  end
end
