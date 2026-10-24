require_relative "b"
require_relative "d"

module C
  def self.run(path) = B.load(path).map { |field| D.render(field) }.join("\n")

  def self.dry_run(path) = B.load(path).size
end
