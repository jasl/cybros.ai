require "fileutils"
require "yaml"

module RhoTest
  # A LOCAL ADAPTATION ROW under a home's `adaptations/`: the SDK pack's row format from Ruby values, written where the
  # daemon reads it at boot. `compose` is the bare word, as the shipped
  # rows spell it; every text field is the operator's to fill.
  module LocalRows
    module_function

    def yaml(id, models: [], tool_style: ["nexus"], tool_descriptions: [], summarizer_prompt: nil,
             lead_hints: [], compose: "on")
      YAML.dump({
        "format" => 1, "row" => id, "models" => models, "tool_style" => tool_style,
        "tool_descriptions" => tool_descriptions, "summarizer_prompt" => summarizer_prompt,
        "lead_hints" => lead_hints, "compose" => compose,
      })
    end

    # Writes `<dir>/<id>.yml` and answers its path.
    def write(dir, id, **fields)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{id}.yml")
      File.write(path, yaml(id, **fields))
      path
    end
  end
end
