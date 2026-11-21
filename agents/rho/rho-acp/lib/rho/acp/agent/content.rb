require "base64"
require "fileutils"
require "securerandom"

module Rho
  module Acp
    class Agent
      # THE CONTENT BLOCKS OF A PROMPT → the words
      # the turn says and the files it attaches. `text` blocks join by a
      # blank line; a `resource` with `text` renders as embedded context —
      # a fenced block headed by its `uri`; a `resource_link` is its `uri` on one
      # line (the runner reads it); an `image` (base64) and a `resource`
      # `blob` whose `mimeType` is `image/*` or `application/pdf` become files under
      # `RHO_HOME/tmp/acp/<session>/`, posted as `attachments:` on the
      # queued turn and DELETED once `say` answered (`Rendered#discard`);
      # any other blob and `audio` are -32602. The surface rewrites no
      # word of the prompt.
      module Content
        Rendered = Data.define(:text, :attachments) do
          def pdf? = attachments.any? { |path| File.extname(path) == ".pdf" }

          # The files are the turn's for the length of the `say` alone.
          def discard
            attachments.each do |path|
              File.delete(path)
            rescue SystemCallError
              nil
            end
            nil
          end
        end

        SEPARATOR = "\n\n".freeze
        EXTENSIONS = {
          "image/png" => "png", "image/jpeg" => "jpg", "image/jpg" => "jpg", "image/gif" => "gif",
          "image/webp" => "webp", "image/bmp" => "bmp", "image/svg+xml" => "svg", "image/tiff" => "tiff",
          Acp::Methods::PDF_MIME_TYPE => "pdf",
        }.freeze

        module_function

        # `blocks` as the wire carried them; `dir` where the attachments land.
        def render(blocks, dir:)
          parts = []
          files = []
          raise Refusal.invalid_params("prompt must be a list of content blocks") unless blocks.is_a?(Array)

          blocks.each_with_index do |block, index|
            raise Refusal.invalid_params("prompt[#{index}] is not a content block") unless block.is_a?(Hash)

            piece, file = render_block(block, index, dir)
            parts << piece unless piece.nil?
            files << file unless file.nil?
          end
          Rendered.new(text: parts.join(SEPARATOR), attachments: files)
        rescue Refusal, SystemCallError, IOError
          Rendered.new(text: "", attachments: files).discard
          raise
        end

        # ---- one block: its words, or its file ----

        def render_block(block, index, dir)
          case block["type"]
          when Acp::Methods::ContentBlock::TEXT then [text_of(block, index), nil]
          when Acp::Methods::ContentBlock::RESOURCE_LINK then [link_of(block, index), nil]
          when Acp::Methods::ContentBlock::RESOURCE then resource_of(block, index, dir)
          when Acp::Methods::ContentBlock::IMAGE then [nil, image_of(block, index, dir)]
          when Acp::Methods::ContentBlock::AUDIO then raise Refusal.invalid_params("prompt[#{index}]: audio is not accepted")
          else raise Refusal.invalid_params("prompt[#{index}]: unknown content block type #{block["type"].inspect}")
          end
        end

        def text_of(block, index)
          text = block["text"]
          raise Refusal.invalid_params("prompt[#{index}]: text must be a string") unless text.is_a?(String)

          text
        end

        def link_of(block, index)
          uri = block["uri"]
          raise Refusal.invalid_params("prompt[#{index}]: resource_link needs a uri") unless uri.is_a?(String) && !uri.empty?

          uri
        end

        # Embedded text becomes context. An image or PDF blob becomes an attachment.
        def resource_of(block, index, dir)
          resource = block["resource"]
          raise Refusal.invalid_params("prompt[#{index}]: resource must carry a resource object") unless resource.is_a?(Hash)

          uri = resource["uri"].to_s
          return [embedded(uri, resource["text"]), nil] if resource["text"].is_a?(String)
          return [nil, blob_file(resource, index, dir)] if resource["blob"].is_a?(String)

          raise Refusal.invalid_params("prompt[#{index}]: resource carries neither text nor blob")
        end

        # The fenced block headed by its uri.
        def embedded(uri, text)
          body = text.end_with?("\n") ? text : "#{text}\n"
          "#{uri}\n```\n#{body}```"
        end

        def image_of(block, index, dir)
          data = block["data"]
          raise Refusal.invalid_params("prompt[#{index}]: image needs base64 data") unless data.is_a?(String) && !data.empty?

          write_file(data, block["mimeType"].to_s, index, dir)
        end

        def blob_file(resource, index, dir)
          mime = resource["mimeType"].to_s
          pdf = mime == Acp::Methods::PDF_MIME_TYPE
          unless pdf || mime.start_with?("image/")
            raise Refusal.invalid_params("prompt[#{index}]: a #{mime.empty? ? "typeless" : mime} blob is not accepted; expected an image or PDF")
          end

          write_file(resource.fetch("blob"), mime, index, dir, pdf: pdf)
        end

        # The bytes decoded strictly (a blob that is not base64 is refused,
        # never written), under the session's tmp dir, 0600.
        def write_file(data, mime, index, dir, pdf: false)
          encoded = data.delete("\n\r ")
          bytes = pdf ? decode_pdf(encoded, index) : Base64.strict_decode64(encoded)
          FileUtils.mkdir_p(dir, mode: 0o700)
          path = File.join(dir, "#{index}-#{SecureRandom.hex(8)}.#{extension(mime)}")
          created = false
          File.open(path, "wbx", 0o600) do |file|
            created = true
            file.write(bytes)
          end
          path
        rescue ArgumentError
          raise Refusal.invalid_params("prompt[#{index}]: the attachment data is not base64")
        rescue SystemCallError, IOError
          FileUtils.rm_f(path) if created
          raise
        end

        def decode_pdf(encoded, index)
          limit = Acp::Methods::PDF_BLOB_MAX_BYTES
          if encoded.empty?
            raise Refusal.invalid_params("prompt[#{index}]: PDF blob needs base64 data")
          end
          if encoded.bytesize > ((limit + 2) / 3) * 4
            raise Refusal.invalid_params("prompt[#{index}]: PDF blob exceeds 16 MiB")
          end

          bytes = Base64.strict_decode64(encoded)
          raise Refusal.invalid_params("prompt[#{index}]: PDF blob exceeds 16 MiB") if bytes.bytesize > limit

          bytes
        end

        def extension(mime)
          EXTENSIONS[mime] || mime.split("/", 2).last.to_s.gsub(/[^a-z0-9]/i, "").then { |ext| ext.empty? ? "img" : ext }
        end
      end
    end
  end
end
