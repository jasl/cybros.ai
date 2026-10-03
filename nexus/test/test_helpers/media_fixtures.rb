require "zlib"

# A solid PNG of any size, as bytes, and the size of any PNG, read off its header: no library draws
# the fixture and no golden bytes are stored — a thumbnail is pinned by its DIMENSIONS, never byte
# for byte, because the re-encode is the image library's.
module PngFixture
  SIGNATURE = "\x89PNG\r\n\x1a\n".b
  # The IHDR chunk follows the signature: 4 length + 4 type, then width
  # and height, four big-endian bytes each.
  IHDR_DIMENSIONS = 16...24

  module_function

  def bytes(width:, height:, rgb: "\xff\x00\x00".b)
    rows = (0...height).map { "\x00".b + (rgb * width) }.join
    SIGNATURE +
      chunk("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNC5")) +
      chunk("IDAT", Zlib::Deflate.deflate(rows)) +
      chunk("IEND", "".b)
  end

  # `[width, height]` of a PNG, or nil for bytes that are not one.
  def dimensions(bytes)
    return nil unless bytes.b.start_with?(SIGNATURE)

    bytes.b[IHDR_DIMENSIONS].unpack("NN")
  end

  def chunk(type, data)
    type = type.b
    data = data.b
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end
end

# The smallest PDF a previewer renders: one blank page. A PDF is
# representable exactly when a previewer accepts it, which is where a
# host's `pdftoppm` presence is decided.
module PdfFixture
  MINIMAL = <<~PDF.b
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >> endobj
    trailer << /Root 1 0 R >>
  PDF
end
