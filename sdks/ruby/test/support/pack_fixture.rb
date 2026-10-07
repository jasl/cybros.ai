require "tmpdir"
require "fileutils"

module CybrosAgentTest
  # A throwaway pack directory: the gem's `presets.yml` (or the caller's
  # bytes) beside the rows given as `{id => yaml}`. A loader test edits one
  # line of a row and reads the refusal that names it.
  module PackFixture
    GEM_DIR = CybrosAgent::ModelAdaptations::DEFAULT_DIR

    module_function

    def default_row_yaml(**fields)
      row_yaml("default", models: [], **fields)
    end

    # A row's YAML from Ruby values, under the same shipped data format.
    def row_yaml(id, models:, tool_style: ["nexus"], tool_descriptions: [], summarizer_prompt: nil,
                 lead_hints: [], extra: {})
      document = {
        "format" => 1, "row" => id, "models" => models, "tool_style" => tool_style,
        "tool_descriptions" => tool_descriptions, "summarizer_prompt" => summarizer_prompt,
        "lead_hints" => lead_hints,
      }.merge(extra)
      YAML.dump(document)
    end

    def with_pack(rows:, presets: nil)
      Dir.mktmpdir("pack") do |dir|
        FileUtils.mkdir_p(File.join(dir, "rows"))
        if presets.nil? then FileUtils.cp(File.join(GEM_DIR, "presets.yml"), File.join(dir, "presets.yml"))
        else File.write(File.join(dir, "presets.yml"), presets)
        end
        rows.each { |id, yaml| File.write(File.join(dir, "rows", "#{id}.yml"), yaml) }
        yield dir
      end
    end

    # A local row file beside a pack, for `extra:`.
    def with_local_row(id, yaml)
      Dir.mktmpdir("local") do |dir|
        path = File.join(dir, "#{id}.yml")
        File.write(path, yaml)
        yield path, dir
      end
    end
  end
end
