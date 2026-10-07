require "fileutils"
require_relative "../support/manual_openrouter_smoke"

E2E::ManualOpenRouter.validate!
directory = File.expand_path("../tmp", __dir__)
FileUtils.mkdir_p(directory)
path = File.join(directory, "openrouter-smoke-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(3)}.jsonl")
summary = File.open(path, "wx", 0o600) do |output|
  E2E::ManualOpenRouterSmoke.new(output: output).run
end
puts JSON.generate(summary.merge("artifact" => path))
exit(1) unless summary.fetch("failed").zero? && summary.fetch("skipped").zero?
