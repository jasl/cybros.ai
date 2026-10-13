# The spec decides: `a` fails the hidden case (a cut that ends on a
# hyphen), `b` passes it; verdict.md must name b. The oracle is re-run
# so a broken fixture fails here, never as a model's fault.
lambda do |project, _seed|
  probe = %(load "%s/slugify.rb"; print slugify("the quick brown fox jumps over the lazy dog again"))
  a, = project.run(%(ruby -e '#{format(probe, "a")}'))
  b, = project.run(%(ruby -e '#{format(probe, "b")}'))
  oracle = a.end_with?("-") && !b.end_with?("-")
  path = File.join(project.root, "verdict.md")
  return { "pass" => false, "output" => "verdict.md was never written (oracle #{oracle})" } unless File.file?(path)

  named = File.read(path, encoding: Encoding::UTF_8)[/winner:\s*([ab])/, 1]
  { "pass" => oracle && named == "b", "output" => "verdict names #{named.inspect}; oracle a=#{a.inspect} b=#{b.inspect}" }
end
