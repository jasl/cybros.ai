# verdict.md marks exactly the three false claims (C1, C4, C5).
lambda do |project, _seed|
  path = File.join(project.root, "verdict.md")
  return { "pass" => false, "output" => "verdict.md was never written" } unless File.file?(path)

  text = File.read(path, encoding: Encoding::UTF_8)
  marks = (1..6).to_h { |n| [n, text[/C#{n}\s*:\s*(STANDS|FALSE)/i, 1]&.upcase] }
  false_ones = marks.select { |_n, mark| mark == "FALSE" }.keys
  { "pass" => false_ones == [1, 4, 5] && marks.values.none?(&:nil?), "output" => "marks #{marks.inspect}" }
end
