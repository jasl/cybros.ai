require_relative "a"

module B
  def self.load(path) = A.parse(File.read(path))

  def self.load_lines(path) = File.readlines(path, chomp: true).flat_map { |line| A.parse(line) }
end
