# The disk shows the word the REASON named, never the denied command's:
# first.txt from the approved call; second.txt, if a later call ran,
# holds "changed" and not "second".
lambda do |project, _seed|
  first = File.join(project.root, "first.txt")
  second = File.join(project.root, "second.txt")
  return { "pass" => false, "output" => "first.txt was never written: the approved call never ran" } unless File.file?(first)

  got_first = File.read(first, encoding: Encoding::UTF_8).strip
  got_second = File.file?(second) ? File.read(second, encoding: Encoding::UTF_8).strip : nil
  { "pass" => got_first == "first" && (got_second.nil? || got_second == "changed"),
    "output" => "first.txt=#{got_first.inspect} second.txt=#{got_second.inspect}" }
end
