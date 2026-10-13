require "zlib"

module E2E
  # A red square on white, as bytes: the signature, IHDR (8-bit RGB), one deflated IDAT of filter-0
  # rows, IEND — each chunk length-typed and CRC'd. No library draws it and no fixture bytes are
  # stored: the SAME bytes on the mock and the paid lane, in the test process and in the harness
  # executor's child.
  module RedSquarePng
    SIDE = 24
    SQUARE = 6..17

    module_function

    def bytes(side: SIDE, square: SQUARE)
      rows = (0...side).map do |y|
        row = "\x00".b
        (0...side).each do |x|
          row << (square.cover?(x) && square.cover?(y) ? "\xff\x00\x00".b : "\xff\xff\xff".b)
        end
        row
      end.join
      "\x89PNG\r\n\x1a\n".b +
        chunk("IHDR", [side, side, 8, 2, 0, 0, 0].pack("NNC5")) +
        chunk("IDAT", Zlib::Deflate.deflate(rows)) +
        chunk("IEND", "".b)
    end

    # `[width, height]` off a PNG's IHDR (the signature, then the chunk's
    # length and type, then the two big-endian sizes), nil for bytes that
    # are not a PNG — a thumbnail is pinned by its dimensions, never byte
    # for byte: the re-encode is the kernel's image library's.
    def dimensions(bytes)
      bytes = bytes.b
      return nil unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)

      bytes[16...24].unpack("NN")
    end

    def chunk(type, data)
      type = type.b
      data = data.b
      [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
    end
  end
end
