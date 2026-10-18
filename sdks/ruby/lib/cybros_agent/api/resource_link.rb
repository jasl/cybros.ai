module CybrosAgent
  module Api
    # A CAPTURE a result names: MCP's own `ResourceLink` block
    # in a commit's `content`, beside the text blocks. `uri` is the one
    # scheme the kernel resolves — `nexus://uploads/<public_id>`, this
    # executor's own staged upload (else `422 unknown_result_upload`) —
    # and `name` is required (MCP `BaseMetadata`); the rest ride verbatim
    # when given. One Data, one constructor, `to_h` the wire block; the
    # builder from an upload descriptor is a runner's own.
    class ResourceLink < Data.define(:uri, :name, :mime_type, :size, :title, :description)
      TYPE = "resource_link".freeze
      URI_PREFIX = "nexus://uploads/".freeze

      def initialize(uri:, name:, mime_type: nil, size: nil, title: nil, description: nil)
        super
      end

      # The block from a staged upload's public id: the wire's `uri` spelled
      # once, here.
      def self.to_upload(public_id, name:, mime_type: nil, size: nil, title: nil, description: nil)
        new(uri: "#{URI_PREFIX}#{public_id}", name: name, mime_type: mime_type, size: size,
          title: title, description: description)
      end

      def to_h
        {
          "type" => TYPE, "uri" => uri, "name" => name, "mimeType" => mime_type,
          "size" => size, "title" => title, "description" => description,
        }.compact
      end
    end
  end
end
