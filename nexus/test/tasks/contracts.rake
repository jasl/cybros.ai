namespace :contracts do
  desc "Regenerate the contracts/nexus/v1 wire-honesty fixture pack"
  task generate: :environment do
    require Rails.root.join("test/support/nexus_contract").to_s

    root = Rails.root.join("../contracts/nexus/v1")
    FileUtils.mkdir_p(root)

    rendered = Nexus::Contract.pack.transform_values { |data| Nexus::Contract.render(data) }
    rendered.each do |name, body|
      File.write(root.join(name), body)
    end
    manifest_name = "manifest.json"
    File.write(root.join(manifest_name), Nexus::Contract.render(Nexus::Contract.manifest(rendered)))

    expected_names = rendered.keys + [manifest_name]
    root.glob("*.json").each do |path|
      FileUtils.rm_f(path) unless expected_names.include?(path.basename.to_s)
    end

    puts "wrote #{rendered.size + 1} files to #{root}"
  end
end
