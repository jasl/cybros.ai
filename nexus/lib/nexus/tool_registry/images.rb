module Nexus
  module ToolRegistry
    module Images
      TOOLS = [
        Tool.new(
          canonical: "nexus.image.generate", name: "image_generate",
          template: <<~TEXT.strip,
            Generate or edit images using this execution's declared image model. Describe the desired image in prompt.
            For edits, reference_upload_public_ids contains the UUIDs of image uploads already available to this run,
            in the order they should be sent. configuration supplies the image model's generation options.
            The call waits for its image task; the result contains durable nexus://uploads resource links.
          TEXT
          parameters: { "type" => "object", "properties" => {
            "prompt" => { "type" => "string", "minLength" => 1 },
            "reference_upload_public_ids" => { "type" => "array", "items" => { "type" => "string", "format" => "uuid" } },
            "configuration" => { "type" => "object" },
          }, "required" => ["prompt"], "additionalProperties" => false },
          effect_profile: GRAPH_WRITE, executor: "Runs::Images::Generate", job: "Runs::ToolDiscoveryJob",
        ),
      ].freeze
    end
  end
end
