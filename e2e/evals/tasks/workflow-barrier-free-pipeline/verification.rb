# merged.txt holds the three normalised records — each source's unique
# value in the record form.
lambda do |project, _seed|
  path = File.join(project.root, "merged.txt")
  return { "pass" => false, "output" => "merged.txt was never written" } unless File.file?(path)

  text = File.read(path, encoding: Encoding::UTF_8)
  want = { "a" => "q7f3k", "b" => "m2z9p", "c" => "x5c1r" }
  present = want.select { |name, value| text.match?(/source=#{name}\b.*value=#{value}/) }.keys
  { "pass" => present.size == 3, "output" => "#{present.size}/3 records normalised: #{text.lines.map(&:strip).first(4).inspect}" }
end
