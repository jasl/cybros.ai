module Mcp
  # Convert only bytes the MCP server already returned. External resource URIs
  # stay readable references; they are never download or credential authority.
  class ResultContent
    def self.call(...) = new(...).call

    def initialize(result:, account:, creator:)
      @result = result
      @account = account
      @creator = creator
    end

    def call
      if @result.key?("resultType") && @result["resultType"] != "complete"
        raise Error.new(:mcp_unsupported_result, request_sent: true)
      end
      unless [nil, true, false].include?(@result["isError"])
        raise Error.new(:mcp_invalid_result, request_sent: true)
      end

      source = Array.try_convert(@result.fetch("content", []))
      raise Error.new(:mcp_invalid_result, request_sent: true) unless source

      content = source.map { |block| adapt(block) }
      structured_present = @result.key?("structuredContent")
      if content.empty? && structured_present
        content << text(JSON.generate(@result["structuredContent"]))
      end
      result = { content: content, structured_content: @result["structuredContent"],
                 structured_content_present: structured_present, is_error: @result["isError"] == true }
      unless Nexus::SizeBounds.json_within?(:snapshot_bound,
          { "content" => content, "structuredContent" => @result["structuredContent"] })
        raise Error.new(:mcp_result_too_large, request_sent: true)
      end
      result
    rescue Nexus::CanonicalJson::UnsupportedValue, JSON::GeneratorError
      raise Error.new(:mcp_invalid_result, request_sent: true), cause: nil
    end

    private

      def adapt(value)
        block = Hash.try_convert(value)
        raise Error.new(:mcp_invalid_result, request_sent: true) unless block

        case block["type"]
        when "text"
          text(block.fetch("text").to_s)
        when "image", "audio"
          upload(block.fetch("data"), name: "mcp-#{block.fetch("type")}")
        when "resource"
          resource(block.fetch("resource"))
        when "resource_link"
          text("External MCP resource (not fetched): #{block.fetch("uri")}")
        else
          text("Unsupported MCP content block: #{block.fetch("type", "unknown")}.")
        end
      rescue KeyError, TypeError, ArgumentError
        raise Error.new(:mcp_invalid_result, request_sent: true), cause: nil
      end

      def resource(value)
        resource = Hash.try_convert(value)
        raise Error.new(:mcp_invalid_result, request_sent: true) unless resource

        if resource.key?("text")
          text(resource.fetch("text").to_s)
        elsif resource.key?("blob")
          upload(resource.fetch("blob"), name: "mcp-resource")
        else
          text("Unsupported MCP embedded resource; no text or bytes were returned.")
        end
      end

      def upload(encoded, name:)
        bytes = Base64.strict_decode64(encoded.to_s)
        Tempfile.create("mcp-content") do |file|
          file.binmode
          file.write(bytes)
          file.rewind
          incoming = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: name)
          created = ContentUploads::Create.call(account: @account, creator: @creator, file: incoming)
          raise Error.new(:mcp_result_too_large, request_sent: true) unless created.accepted?

          saved = created.upload
          { "type" => "resource_link", "uri" => "nexus://uploads/#{saved.public_id}",
            "name" => saved.file.filename.to_s, "mimeType" => saved.file.content_type, "size" => saved.file.byte_size }
        end
      end

      def text(value) = { "type" => "text", "text" => value }
  end
end
