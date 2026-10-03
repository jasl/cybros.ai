# THE WORK SURVIVED IT: every file indexed, each first line real — a
# wrong line was invented (the summary's defect) or read in part.
lambda do |project, _seed|
  expected = project.files.select { |path, _| path.start_with?("corpus/doc-") }
    .to_h { |path, contents| [File.basename(path), contents.lines.first.to_s.chomp] }
  index = File.join(project.root, "index.txt")
  return { "pass" => false, "output" => "index.txt was never written" } unless File.file?(index)

  lines = File.read(index, encoding: Encoding::UTF_8).lines.map(&:strip).reject(&:empty?)
  got = lines.filter_map { |l| l.split(":", 2).map(&:strip) if l.include?(":") }.to_h
  missing = expected.keys - got.keys
  wrong = expected.select { |name, first| got[name] && got[name] != first }.keys
  { "pass" => missing.empty? && wrong.empty?,
    "output" => "#{lines.size} lines; missing #{missing.size} wrong #{wrong.size} of #{expected.size}; " \
                "duplicated #{lines.tally.count { |_, n| n > 1 }}#{wrong.first(2).map { |n| " | wrong #{n}: #{got[n].inspect}" }.join}" }
end
