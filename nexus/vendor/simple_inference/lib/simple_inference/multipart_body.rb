module SimpleInference
  # A multipart request body that is ITERATED rather than assembled.
  #
  # The whole point is what it does NOT do: build one String holding the
  # entire message. A transcription send used to cost twice the file — the
  # bytes once, and the concatenated body once more — and no byte could leave
  # the process until the last one had been copied.
  #
  # It answers `each` and `bytesize`, which is the pair every transport here
  # needs: httpx reads `bytesize` for Content-Length before it iterates, and
  # streams what `each` yields. Declaring the length up front is what keeps
  # this a plain sized request rather than a chunked one, which not every
  # provider accepts on a multipart upload.
  #
  # Every segment is an emitter normalized while the multipart request is
  # compiled. A file source is opened inside `each` and closed by whatever
  # opened it, so the file's lifetime is exactly one iteration and nothing
  # holds a descriptor between compile and send.
  class MultipartBody
    include Enumerable

    def initialize(segments, byte_size)
      @segments = segments
      @bytesize = byte_size
    end

    attr_reader :bytesize

    def each(&block)
      return enum_for(:each) unless block

      @segments.each { |segment| segment.call(&block) }
    end

    # The transports here never ask for this, and something else might: a body
    # that can only be iterated is a body some caller will quietly turn into
    # its own inspect string. Answering honestly costs one full copy, which is
    # exactly what iterating avoids — so it exists, and nothing internal uses
    # it.
    def to_s
      each_with_object(+"".b) { |chunk, out| out << chunk }
    end
  end
end
