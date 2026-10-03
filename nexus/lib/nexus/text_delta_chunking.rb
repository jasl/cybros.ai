module Nexus
  # Splits streamed text into durable-item-sized chunks without cutting a
  # multibyte character; the joined chunks equal the original byte for byte.
  module TextDeltaChunking
    TEXT_DELTA_CHUNK_BYTES = 16 * 1024

    module_function

    def chunk(text, bytes: TEXT_DELTA_CHUNK_BYTES)
      return [] if text.empty?

      chunks = []
      current = +""
      text.each_char do |char|
        if current.bytesize + char.bytesize > bytes && !current.empty?
          chunks << current
          current = +""
        end
        current << char
      end
      chunks << current unless current.empty?
      chunks
    end
  end
end
