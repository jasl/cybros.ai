# Turn 1 did the work on disk.
lambda do |project, _seed|
  path = File.join(project.root, "hello.txt")
  return { "pass" => false, "output" => "hello.txt was never written" } unless File.file?(path)

  word = File.read(path, encoding: Encoding::UTF_8).strip
  { "pass" => word == "hello", "output" => "hello.txt=#{word.inspect}" }
end
