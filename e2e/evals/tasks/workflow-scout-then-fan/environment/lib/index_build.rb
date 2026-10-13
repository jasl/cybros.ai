# Builds a word index over a set of documents.
class IndexBuild
  def initialize(documents)
    @documents = documents
  end

  def run
    @documents.each_with_object(Hash.new { |hash, word| hash[word] = [] }) do |(id, text), index|
      text.downcase.scan(/\w+/).uniq.each { |word| index[word] << id }
    end
  end
end
