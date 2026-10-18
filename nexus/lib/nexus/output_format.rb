module Nexus
  OutputFormat = Data.define(:type, :name, :schema, :strict) do
    def self.text = new(type: "text", name: nil, schema: nil, strict: nil)

    def self.from_h(hash)
      new(
        type: hash.fetch("type"),
        name: hash["name"],
        schema: hash["schema"],
        strict: hash["strict"]
      )
    end

    def to_h
      case type
      when "text", "json_object"
        { "type" => type }
      when "json_schema"
        {
          "type" => type,
          "name" => name,
          "schema" => schema,
          "strict" => strict,
        }
      else
        raise ArgumentError, "unsupported output format: #{type.inspect}"
      end
    end

    def request_options
      case type
      when "text", "json_object"
        { type: type }
      when "json_schema"
        { type: type, name: name, schema: schema, strict: strict }
      else
        raise ArgumentError, "unsupported output format: #{type.inspect}"
      end
    end
  end
end
