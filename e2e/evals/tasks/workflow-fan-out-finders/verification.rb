# findings.md names every file's token, read from the fixture itself so
# the tokens live in one place.
lambda do |project, _seed|
  tokens = project.files.select { |path, _| path.start_with?("lib/") }.to_h do |path, contents|
    [path, contents[/TODO\(sec\) (\S+)/, 1]]
  end
  findings = File.join(project.root, "findings.md")
  return { "pass" => false, "output" => "findings.md was never written" } unless File.file?(findings)

  text = File.read(findings, encoding: Encoding::UTF_8)
  missing = tokens.reject { |_path, token| text.include?(token) }.keys
  { "pass" => missing.empty?, "output" => "#{tokens.size - missing.size}/#{tokens.size} tokens named; missing #{missing.inspect}" }
end
