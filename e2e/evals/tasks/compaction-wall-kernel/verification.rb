# THE WORK SURVIVED: every out/ file is the source with its line numbers,
# exactly; INDEX.md lists every file with its line count.
lambda do |project, _seed|
  sources = project.files.select { |path, _| path.start_with?("src/part-") }
  wrong = sources.reject do |path, contents|
    want = contents.lines.each_with_index.map { |line, i| "#{i + 1}: #{line}" }.join
    out = File.join(project.root, "out", File.basename(path))
    File.file?(out) && File.read(out, encoding: Encoding::UTF_8).chomp == want.chomp
  end.keys.map { |path| File.basename(path) }
  index = File.join(project.root, "INDEX.md")
  listed = File.file?(index) ? File.read(index, encoding: Encoding::UTF_8) : ""
  unlisted = sources.keys.map { |path| File.basename(path) }.reject { |name| listed.match?(/^#{Regexp.escape(name)}: \d+/) }
  { "pass" => wrong.empty? && unlisted.empty?,
    "output" => "#{sources.size - wrong.size}/#{sources.size} copies exact (wrong #{wrong.first(3).inspect}); unlisted #{unlisted.size}" }
end
