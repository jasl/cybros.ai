# review.md names exactly the files under lib/ that define a class with a `call` method, and none of
# the others — the two modules holding a `def call` among them. The five are read from the fixture
# itself, so they live in one place.
lambda do |project, _seed|
  sources = project.files.select { |path, _| path.start_with?("lib/") }
  callers = sources.select { |_path, text| text.match?(/^class /) && text.match?(/^\s+def call\b/) }.keys
  review = File.join(project.root, "review.md")
  return { "pass" => false, "output" => "review.md was never written" } unless File.file?(review)

  text = File.read(review, encoding: Encoding::UTF_8)
  named = sources.keys.select { |path| text.include?(path) }
  missing = callers - named
  extra = named - callers
  { "pass" => missing.empty? && extra.empty?,
    "output" => "#{named.size - extra.size}/#{callers.size} callers named; missing #{missing.sort.inspect}; not a caller #{extra.sort.inspect}" }
end
