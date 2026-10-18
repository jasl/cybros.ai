# The work survived the arm: done.txt was written after the compacted
# round; the reply's word is read by the predicate.
lambda do |project, _seed|
  path = File.join(project.root, "done.txt")
  return { "pass" => false, "output" => "done.txt was never written" } unless File.file?(path)

  word = File.read(path, encoding: Encoding::UTF_8).strip
  { "pass" => word == "done", "output" => "done.txt=#{word.inspect}" }
end
