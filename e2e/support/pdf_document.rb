module E2E
  # A complete single-page document for file transport tests. Byte-derived
  # offsets keep it readable by a PDF viewer without a fixture dependency.
  module PdfDocument
    module_function

    def bytes(marker = "Native document fixture")
      stream = "BT /F1 12 Tf 20 80 Td (#{marker}) Tj ET\n"
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      ]
      pdf = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |body, index|
        offset = pdf.bytesize
        pdf << "#{index + 1} 0 obj\n#{body}\nendobj\n"
        offset
      end
      xref = pdf.bytesize
      pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
      pdf << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    end
  end
end
