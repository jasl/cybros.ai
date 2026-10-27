module SimpleInference
  module Decisions
    Input = Data.define(:value, :kind) do
      def self.from_value(value)
        encoded = JSON.generate(value)
        kind = { '"' => :text, "{" => :json, "[" => :json }[encoded[0]]
        raise SimpleInference::ValidationError, "decision input must be text, an object or an array" unless kind

        new(value: JSON.parse(encoded), kind: kind)
      rescue JSON::GeneratorError => error
        raise SimpleInference::ValidationError, "invalid decision input", cause: error
      end
    end
  end
end
