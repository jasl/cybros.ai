# Walks the entries of an archive already read into memory.
class ZipReader
  def initialize(entries)
    @entries = entries
  end

  def names
    @entries.map { |entry| entry.fetch(:name) }
  end

  def read(name)
    @entries.find { |entry| entry.fetch(:name) == name }&.fetch(:data)
  end
end
