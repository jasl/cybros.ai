require_relative "render/markdown"

module Rho
  module IngressTelegram
    module Render
      TEXT_LIMIT = 4096
      PREVIEW_LIMIT = 800

      Chunk = Data.define(:text, :html) do
        def formatted
          { text: html, parse_mode: "HTML" }
        end

        def plain
          { text: text }
        end
      end

      module_function

      # Split rendered text, never serialized HTML: tags are balanced in each
      # message, and the fallback has exactly the same visible text and boundaries.
      def chunks(text, limit: TEXT_LIMIT, plain: false)
        raise ArgumentError, "Message limit must be at least 32" if limit < 32

        spans = plain ? [Span.new(text: text.to_s, tags: [])] : Document.new(text.to_s).spans
        result = []
        visible, html = +"", +""
        budget = limit
        spans.each do |span|
          remaining = span.text
          until remaining.empty?
            piece, rest = take_piece(remaining, budget, split_cluster: visible.empty?)
            if piece.empty?
              result << Chunk.new(text: visible, html: html)
              visible, html, budget = +"", +"", limit
              next
            end
            visible << piece
            html << span.tags.map(&:first).join << escape(piece) << span.tags.reverse.map(&:last).join
            budget -= utf16_length(piece)
            remaining = rest
            unless rest.empty?
              result << Chunk.new(text: visible, html: html)
              visible, html, budget = +"", +"", limit
            end
          end
        end
        result << Chunk.new(text: visible, html: html) unless visible.empty?
        result
      end

      def escape(text)
        text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
      end

      def preview(text, limit: PREVIEW_LIMIT)
        source = text.to_s
        return source if utf16_length(source) <= limit

        budget = [limit - 1, 0].max
        prefix = +""
        source.each_grapheme_cluster do |cluster|
          size = utf16_length(cluster)
          break if size > budget

          prefix << cluster
          budget -= size
        end
        limit.positive? ? "#{prefix}…" : ""
      end

      def utf16_length(text)
        text.encode(Encoding::UTF_16LE).bytesize / 2
      end

      def take_piece(text, budget, split_cluster:)
        size = 0
        count = 0
        text.each_grapheme_cluster do |cluster|
          size += utf16_length(cluster)
          break if size > budget

          count += cluster.length
        end
        if count.zero? && split_cluster
          # A single pathological combining sequence can exceed Telegram's text
          # limit. Preserve every codepoint over parts instead of losing content.
          size = 0
          text.each_char do |character|
            size += character.ord > 0xffff ? 2 : 1
            break if size > budget

            count += 1
          end
        end
        piece = text[0, count]
        if count < text.length
          # Prefer paragraphs, then lines; never discard the separating bytes.
          boundary = piece.rindex("\n\n")
          boundary = piece.rindex("\n") if !boundary || boundary < count / 2
          count = boundary + 1 if boundary && boundary >= count / 2
        end
        [text[0, count], text[count..]]
      end
      private_class_method :take_piece
    end
  end
end
