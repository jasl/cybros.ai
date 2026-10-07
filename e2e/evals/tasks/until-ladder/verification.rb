# note.txt holds the word, and the daemon's check ran at least twice.
lambda do |project, _seed|
  note = File.join(project.root, "note.txt")
  count = File.join(project.root, ".check-count")
  return { "pass" => false, "output" => "note.txt was never written" } unless File.file?(note)

  word = File.read(note, encoding: Encoding::UTF_8).strip
  runs = File.file?(count) ? Integer(File.read(count).strip) : 0
  { "pass" => word == "hello" && runs >= 2, "output" => "note.txt=#{word.inspect} checks=#{runs}" }
end
