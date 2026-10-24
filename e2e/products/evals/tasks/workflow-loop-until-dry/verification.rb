# Every item's result on disk, doubled, and the queue empty.
lambda do |project, _seed|
  items = project.files.select { |path, _| path.start_with?("queue/item-") }.to_h { |path, n| [File.basename(path), Integer(n.strip) * 2] }
  wrong = items.reject do |name, want|
    path = File.join(project.root, "results", name)
    File.file?(path) && File.read(path, encoding: Encoding::UTF_8).strip == want.to_s
  end.keys
  queue = File.join(project.root, "queue")
  # A queue directory the model removed once it was drained is an empty queue, not a raise.
  left = File.directory?(queue) ? Dir.children(queue).reject { |f| f.start_with?(".") } : []
  { "pass" => wrong.empty? && left.empty?, "output" => "#{items.size - wrong.size}/#{items.size} results right; queue left #{left.inspect}" }
end
