require "fileutils"
require "json"
require "rho/runner"

work = ARGV.fetch(0)
root = File.join(work, "announced-project")
bound_root = File.join(work, "bound-project")
FileUtils.mkdir_p([root, bound_root])

loaded = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding])
abort "Coding extension did not load: #{loaded.failures.inspect}" unless loaded.ok?
registry = loaded.registry.serving(:runner)
documents = registry.documents(Rho::Runner::Environment.local(root: root))
abort "workspace-tools was not announced: #{documents.inspect}" unless documents.map { |row| row.fetch("name") } == ["workspace-tools"]
File.write(File.join(work, "workspace-tools-announcement.json"), JSON.pretty_generate(documents) + "\n")

environments = [
  Rho::Runner::ToolEnv.new(root: root, artifacts_dir: work),
  Rho::Runner::ToolEnv.new(root: bound_root, documents_root: root, artifacts_dir: work),
]
contents = environments.map do |env|
  result = registry.toolset(env: env).fetch("skill").handler.call({ "name" => "workspace-tools" }, nil)
  abort "workspace-tools failed to load: #{result.content}" if result.is_error
  ["# Workspace tools in the rho image", "/opt/cowork/bin", "from docx import Document", "## Browser QA"].each do |text|
    abort "workspace-tools is missing #{text.inspect}" unless result.content.include?(text)
  end
  result.content
end
abort "binding changed the announced guide" unless contents.first == contents.last
File.write(File.join(work, "workspace-tools-loaded.md"), contents.first + "\n")
puts "workspace-tools was announced and loaded through skill before and after directory binding"
