namespace :openapi do
  desc "Generate and validate the current OpenAPI 3.2 description"
  task check: :environment do
    path = Rails.root.join("tmp/openapi.json")
    FileUtils.mkdir_p(path.dirname)
    File.write(path, JSON.pretty_generate(Nexus::Openapi.build) << "\n")
    sh "bun", "node_modules/@redocly/cli/bin/cli.js", "lint", path.to_s,
      "--config", Rails.root.join("config/openapi/redocly.yaml").to_s
  end
end
