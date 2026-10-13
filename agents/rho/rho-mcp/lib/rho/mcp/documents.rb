require "rho/runner"

module Rho
  module Mcp
    # PROMPTS AND RESOURCES AS DOCUMENTS: each listed
    # at LOAD beside the tools and curated into a `{name, description}`
    # entry under the kernel's skill grammar — the name by
    # `Naming.document`, the description the server's own, VERBATIM — on
    # the SERVER's row (a stdio server's ride the runner address, an http
    # server's the agent's). Curated OUT, with the reason `rho mcp` prints:
    # a prompt with a REQUIRED argument (`skill {name}` carries none); a
    # prompt or resource with no description, or one past the grammar's
    # 1024 bytes (a catalog line the model cannot choose from is not a
    # document); a resource whose listing names an EXPLICIT mimeType that
    # is neither text, an image nor a PDF (a blob nobody can read); a name a
    # sibling on the same server already took. A resource with NO listing
    # mimeType — the common case — is announced, and the READ decides by
    # `text` vs `blob`. Resource templates are not documents (the probe
    # lists them). The LOAD is the address's `skill` row: a prompt's
    # messages' text, a resource's text verbatim, a binary image or PDF resource
    # a CAPTURE named in `Result#files` beside one line — the runner's one
    # upload site links it; another binary type keeps the placeholder line.
    module Documents
      TEXT_TYPES = %r{\Atext/|\Aapplication/(?:[\w.-]+\+)?(?:json|xml|yaml|x-yaml|toml)\z}i
      DESCRIPTION_MAX_BYTES = 1024
      ASSISTANT_LINE = "assistant:".freeze

      # One announced document: the announcement's two facts and the load's.
      Announced = Data.define(:name, :kind, :raw_name, :uri, :description, :mime_type) do
        def entry = { "name" => name, "description" => description }
        def prompt? = kind == "prompt"
      end
      Skipped = Data.define(:name, :kind, :reason)
      Curated = Data.define(:announced, :skipped) do
        def entries = announced.map(&:entry)
        def find(name) = announced.find { |document| document.name == name }
        def names = announced.map(&:name)
      end

      module_function

      # `prompts` and `resources` are the listings as the SDK hands them
      # (Hashes with string keys); the order is prompts then resources, each
      # in the server's listing order.
      def curate(row, prompts, resources)
        announced = []
        skipped = []
        Array(prompts).each { |prompt| place(announced, skipped, row, prompt, "prompt") }
        Array(resources).each { |resource| place(announced, skipped, row, resource, "resource") }
        Curated.new(announced: announced.freeze, skipped: skipped.freeze)
      end

      def place(announced, skipped, row, listing, kind)
        listing = Hash.try_convert(listing) || {}
        raw = listing["name"].to_s
        name = Naming.document(row.key, raw.empty? ? listing["uri"].to_s : raw)
        reason = reason_to_skip(listing, kind, raw, name, announced)
        if reason
          skipped << Skipped.new(name: name, kind: kind, reason: "#{kind}: #{reason}")
          return
        end

        announced << Announced.new(name: name, kind: kind, raw_name: raw, uri: listing["uri"],
          description: listing["description"].to_s.dup.freeze, mime_type: listing["mimeType"])
      end

      def reason_to_skip(listing, kind, raw, name, announced)
        return "no name" if raw.empty?

        description = listing["description"].to_s
        return "no description" if description.strip.empty?
        return "description exceeds #{DESCRIPTION_MAX_BYTES} bytes" if description.bytesize > DESCRIPTION_MAX_BYTES

        taken = announced.find { |document| document.name == name }
        return "name #{name} is already announced by the #{taken.kind} #{taken.raw_name.inspect}" if taken

        kind == "prompt" ? prompt_reason(listing) : resource_reason(listing)
      end

      def prompt_reason(listing)
        required = Array(listing["arguments"]).find { |argument| Hash.try_convert(argument)&.dig("required") == true }
        required ? "required argument #{required["name"].to_s.inspect}" : nil
      end

      def resource_reason(listing)
        mime = listing["mimeType"]
        return nil if mime.nil? || mime.to_s.empty? || text_type?(mime) || Mapping::CAPTURE_EXTENSIONS.key?(mime.to_s)

        mime.to_s
      end

      def text_type?(mime) = mime.to_s.match?(TEXT_TYPES)

      # ---- the bodies ----

      # A prompt's `messages` (`prompts/get`): each message's text blocks
      # joined by "\n", messages joined by a blank line, an `assistant`
      # message prefixed by one `assistant:` line (the common all-`user`
      # case renders bare text — a skill body is instructions, not a
      # transcript); an image, audio or resource block inside a prompt
      # follows a tool result's rules (a capture, the audio line, the
      # `resource:` line).
      def prompt_result(raw, server:, name:, env: nil)
        raw = Hash.try_convert(raw) || {}
        files = []
        paragraphs = Array(raw["messages"]).each_with_index.map do |message, index|
          message = Hash.try_convert(message) || {}
          blocks = (message["content"] in Array) ? message["content"] : [message["content"]]
          lines = blocks.each_with_index.map do |block, position|
            Mapping.line(block, server: server, env: env, stem: "#{name}-#{index}-#{position}", files: files)
          end
          text = lines.compact.join("\n")
          message["role"].to_s == "assistant" ? "#{ASSISTANT_LINE}\n#{text}" : text
        end
        Rho::Runner::Result.ok(paragraphs.join("\n\n"), files: files)
      end

      # A resource's `contents` (`resources/read`): text verbatim, joined;
      # an image or PDF blob decoded under the artifacts dir as `mcp/<server>/
      # <name>.<ext>` and named in `files` beside one line; another binary
      # type keeps the placeholder line.
      def resource_result(contents, server:, name:, env: nil)
        files = []
        lines = Array(contents).each_with_index.map do |item, index|
          item = Hash.try_convert(item) || {}
          next item["text"].to_s if item.key?("text")

          mime = item["mimeType"].to_s
          if item.key?("blob") && Mapping::CAPTURE_EXTENSIONS.key?(mime) && !env.nil?
            next resource_capture(item, mime, server, env, index.zero? ? name : "#{name}-#{index}", files)
          end

          "[resource: #{item["uri"]} (#{mime.empty? ? "unknown type" : mime}), content discarded]"
        end
        Rho::Runner::Result.ok(lines.join("\n"), files: files)
      end

      # The capture's own line names the document, the type and the bytes
      # (the probe has no env: the placeholder line above, never a file).
      def resource_capture(item, mime, server, env, stem, files)
        Mapping.capture(item["blob"], mime, server, env, stem, files, "resource")
        path = files.last
        "#{stem}: #{mime}, #{Mapping.number(File.size(path))} bytes — saved at #{path} and attached"
      end
    end
  end
end
