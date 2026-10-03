require "base64"
require "fileutils"
require "json"
require "securerandom"
require "rho/runner"

module Rho
  module Mcp
    # THE RESULT MAPPING: a `CallToolResult`'s content blocks, in order, into the runner's
    # `Result` — text only, an image a CAPTURE named in `Result#files` (the runner uploads
    # it and links a `resource_link` beside the text, THE ONE UPLOAD SITE), audio ONE
    # placeholder line (omitted from the result), an embedded resource its text or, when
    # binary and an image, a capture, a `resource_link` one text line (a URI on the server's
    # namespace nobody here can resolve), an unknown type a bracketed line.
    # `structuredContent` rides verbatim as `structured_content` (the UI's channel); when
    # the server sent NO text and did send structure, the structure is serialized into the
    # text — MCP's own SHOULD, the client's duty now that the kernel's empty-text fallback
    # is cut. `isError` is the two-axis law's first axis: the tool RAN and said so, the
    # model reads it. The failure sentences and the notice line live here too, with the
    # model-facing tail CAPPED at 3 lines / 512 bytes (a server's stderr is server-authored
    # bytes into the context).
    module Mapping
      TAIL_LINES = 3
      TAIL_BYTES = 512
      IMAGE_EXTENSIONS = {
        "image/png" => "png", "image/jpeg" => "jpg", "image/jpg" => "jpg", "image/gif" => "gif",
        "image/webp" => "webp", "image/svg+xml" => "svg",
      }.freeze

      module_function

      # `raw` is the response's `result` hash; `env` the tool's `ToolEnv`
      # (nil under a probe — then an image is the placeholder line).
      def result(raw, server:, env: nil)
        raw = Hash.try_convert(raw) || {}
        files = []
        lines = Array(raw["content"]).map { |block| line(block, server: server, env: env, stem: nil, files: files) }
        structured = raw["structuredContent"]
        text = lines.compact.join("\n")
        text = JSON.generate(structured) if text.empty? && !structured.nil?
        constructor = raw["isError"] == true ? :error : :ok
        Rho::Runner::Result.public_send(constructor, text, structured, files: files)
      end

      def with_notice(result, notice)
        return result if notice.nil?

        result.with(content: "#{notice}\n#{result.content}")
      end

      # One content block to one text line; `stem` names a capture's file
      # for a prompt's or resource's block (the document's name and the
      # block's place), and a tool result's has none: its capture is named
      # by its content.
      def line(block, server:, env:, stem:, files:)
        block = Hash.try_convert(block) || {}
        case block["type"]
        when "text" then block["text"].to_s
        when "image" then capture(block["data"], block["mimeType"], server, env, stem, files, "image")
        when "audio" then "[audio: #{block["mimeType"]}, content discarded]"
        when "resource" then embedded(block["resource"], server, env, stem, files)
        when "resource_link" then "resource: #{block["uri"]} (#{block["mimeType"] || "unknown type"})"
        else "[unsupported content type: #{block["type"]}]"
        end
      end

      def embedded(resource, server, env, stem, files)
        resource = Hash.try_convert(resource) || {}
        return resource["text"].to_s if resource.key?("text")

        mime = resource["mimeType"].to_s
        if resource.key?("blob") && IMAGE_EXTENSIONS.key?(mime)
          return capture(resource["blob"], mime, server, env, stem, files, "resource")
        end

        "[resource: #{resource["uri"]} (#{mime.empty? ? "unknown type" : mime}), content discarded]"
      end

      # The decoded bytes under the artifacts dir as `mcp/<server>/<stem>.
      # <ext>`, named in `files`; the text half names the path for the
      # model (`read` on the same runner). Without a stem — a tool result's
      # block — the file is written under a temporary name and kept as
      # `<kind>-<digest>.<ext>` (`ToolEnv#keep_capture`): the text names the
      # path, so a name carrying the task's key would make the same picture
      # read as a new result on every call.
      def capture(data, mime, server, env, stem, files, kind)
        return "[#{kind}: #{mime}, content discarded]" if env.nil?

        bytes = Base64.decode64(data.to_s)
        extension = IMAGE_EXTENSIONS.fetch(mime.to_s, "bin")
        directory = File.join(env.ensure_artifacts_dir!, "mcp", server)
        FileUtils.mkdir_p(directory, mode: 0o700)
        path = File.join(directory, "#{stem || "#{kind}-#{SecureRandom.hex(8)}"}.#{extension}")
        File.binwrite(path, bytes)
        path = env.keep_capture(path, kind) if stem.nil?
        files << path
        "[#{kind}: #{mime}, #{bytes.bytesize} bytes — saved at #{path} and attached]"
      end

      def number(value) = value.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

      # The last three lines and 512 bytes of a stderr tail, for a sentence
      # a model reads; the 4 KiB tail is for the log.
      def capped_tail(tail)
        text = tail.to_s.strip
        return "" if text.empty?

        capped = text.lines.last(TAIL_LINES).join.strip
        capped = capped.byteslice(-TAIL_BYTES..).to_s.scrub.lstrip if capped.bytesize > TAIL_BYTES
        capped
      end

      def tail_clause(tail)
        capped = capped_tail(tail)
        capped.empty? ? "" : "; its stderr ended: #{capped}"
      end
    end
  end
end
