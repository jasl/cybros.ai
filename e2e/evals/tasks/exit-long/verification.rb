# THE ACCEPTANCE (live_exit_long_test.rb:154-160, 515-531): the suite's
# own exit, the specification untouched, the index real (each line the
# first line AND the marker line only a whole read could produce), the
# server's token in the port.
shipped = %w[src/frame_codec.js test/frame_codec_test.rb test/spec_token_test.rb test/all.rb check.sh PORT.md]
lambda do |project, seed|
  output, status = project.run("ruby -Ilib -Itest test/all.rb")
  changed = project.changed(shipped)
  vectors = project.files.select { |path, _| path.start_with?("spec/vectors/vec-") }
  expected = vectors.to_h do |path, contents|
    lines = contents.lines(chomp: true)
    [File.basename(path), "#{lines.first} | #{lines.find { |line| line.start_with?("marker-") }}"]
  end
  index = File.join(project.root, "VECTORS.md")
  lines = File.file?(index) ? File.read(index, encoding: Encoding::UTF_8).lines.map { |l| l.strip.sub(/\A[-*]\s+/, "") }.reject(&:empty?) : []
  got = lines.filter_map { |l| l.split(":", 2).map(&:strip) if l.include?(":") }.to_h
  missing = expected.keys - got.keys
  wrong = expected.select { |name, line| got[name] && got[name] != line }.keys
  token = project.run(%(ruby -Ilib -e 'require "frame_codec"; print FrameCodec::SPEC_TOKEN')).first.strip
  { "pass" => status.success? && changed.empty? && missing.empty? && wrong.empty? && token == seed.secret,
    "output" => "suite #{status.success? ? "green" : "RED"}; changed shipped: #{changed.inspect}; index missing #{missing.size} wrong #{wrong.size} " \
                "of #{expected.size}; token #{token == seed.secret ? "matches" : "differs"}; #{output.lines.last(3).join}" }
end
