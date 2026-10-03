module E2E
  module ComposeBench
    # THE HARNESS'S OWN TOOLS, declared beside `compose` on every call: the
    # smallest set the objectives can be stated against, fixed for every
    # objective so the prefix is cache-shaped like production. `read_file`
    # is the matrix's historic tool (the over-reach control wants one
    # call's worth of work); `grep`, `edit` and `bash` carry rho's names so
    # the objectives read like a repository task; `probe_host` is what a
    # race has to race.
    module Tools
      def self.function(name, description, properties, required)
        { type: "function",
          function: { name: name, description: description,
                      parameters: { type: "object", properties: properties, required: required } } }.freeze
      end

      READ_FILE = function("read_file", "Read one file and return its contents.",
        { path: { type: "string" } }, ["path"])
      GREP = function("grep", "Search one file for a pattern. Returns the matching lines as file:line: text.",
        { pattern: { type: "string" }, path: { type: "string" } }, %w[pattern path])
      EDIT = function("edit", "Replace one exact passage in a file. `old_text` must occur exactly once.",
        { path: { type: "string" }, old_text: { type: "string" }, new_text: { type: "string" } },
        %w[path old_text new_text])
      BASH = function("bash", "Run one shell command in the repository and return its output.",
        { command: { type: "string" } }, ["command"])
      PROBE_HOST = function("probe_host", "Check whether one host responds. Returns its status.",
        { host: { type: "string" } }, ["host"])

      DECLARED = [READ_FILE, GREP, EDIT, BASH, PROBE_HOST].freeze
      NAMES = DECLARED.map { |tool| tool.dig(:function, :name) }.freeze

      # The registry's wire shape (string keys), for the capture manifest
      # the nexus replay declares beside compose.
      def self.function_definitions
        DECLARED.map do |tool|
          { "type" => "function", "function" => JSON.parse(JSON.generate(tool[:function])) }
        end
      end
    end
  end
end
