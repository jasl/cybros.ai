# The proof is on disk: the word the human answered, and nothing else.
lambda do |project, seed|
  path = File.join(project.root, "greeting.txt")
  return { "pass" => false, "output" => "greeting.txt was never written" } unless File.file?(path)

  word = File.read(path, encoding: Encoding::UTF_8).strip
  { "pass" => word == seed.secret, "output" => "greeting.txt=#{word.inspect}" }
end
