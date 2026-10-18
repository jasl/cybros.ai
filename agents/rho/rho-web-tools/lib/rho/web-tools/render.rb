require "nokogiri"
require "reverse_markdown"

module Rho
  module WebTools
    # THE RENDER: what the bytes of a `Page` mean to a
    # model, by the response's media type. HTML is parsed by nokogiri's
    # HTML5 parser (Rails' own) with the script/style/noscript/template/
    # svg/iframe/object/embed subtrees removed, its `<title>` lifted for the
    # status line, and converted by reverse_markdown — Ruby's turndown —
    # with NO inline options: `convert(node, opts)` writes them onto the
    # gem's one module-level `Config` without a lock, and the registry
    # shares one tool instance across every worker thread, so the config
    # is written ONCE at `register` and `with({})` is idempotent under a
    # parallel fan (`render_test.rb` pins two threads). Other text is the
    # body verbatim; everything else is bytes the adapter saves.
    # The render input is cut at `RENDER_INPUT_BYTES` before the parse (claude-code's shape,
    # `CHANGELOG.md:3501`; the cut named in the status line as `rendered the first N of M`):
    # reverse_markdown is superlinear past 1 MiB.
    module Render
      class Unrenderable < Error; end

      # `kind` is :markdown, :verbatim or :bytes; `text` is UTF-8 and clean
      # (nil for bytes); `title` is the HTML `<title>` or nil; `cut` is the
      # byte count rendered when the input was cut, else nil.
      Rendering = Data.define(:kind, :text, :title, :cut)

      RENDER_INPUT_BYTES = 1_048_576
      HTML_TYPES = %w[text/html application/xhtml+xml].freeze
      TEXT_TYPES = %w[application/json application/xml application/javascript].freeze
      STRUCTURED_SUFFIXES = %w[+json +xml].freeze
      DROPPED = "script, style, noscript, template, svg, iframe, object, embed".freeze
      # Zero-width and bidi characters read one way to a terminal and
      # another to a model; every C0 control but `\n`, `\t` (and `\r`), DEL
      # and the C1 range likewise — rho-mcp's `Commands::INVISIBLE`, the
      # same class by value (rho-web-tools cannot depend on rho-mcp). Stripped
      # from the RENDER, so the model reads none; `scrub` repairs only
      # invalid UTF-8.
      INVISIBLE = /[\u200B-\u200F\u2028-\u202E\u2060-\u2064\uFEFF\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/

      module_function

      def call(page)
        if html?(page.media_type)
          markdown(page.body, charset: page.charset)
        elsif text?(page.media_type)
          Rendering.new(kind: :verbatim, text: clean(decode(page.body, page.charset)), title: nil, cut: nil)
        else
          Rendering.new(kind: :bytes, text: nil, title: nil, cut: nil)
        end
      end

      def html?(media_type) = HTML_TYPES.include?(media_type.to_s)

      def text?(media_type)
        type = media_type.to_s
        type.start_with?("text/") || TEXT_TYPES.include?(type) || STRUCTURED_SUFFIXES.any? { |s| type.end_with?(s) }
      end

      # THE PAGE'S ENCODING, in WHATWG's order: the `Content-Type` charset,
      # then a `<meta>` declaration in the first 1024 bytes, each decoded
      # here with replacement as `decode` does for text (nokogiri's own
      # transcode has no fallback, so one byte a legacy multibyte charset
      # cannot map, or the cut through a character, would fail the page).
      # A byte-order mark is nokogiri's to read. With no declaration at all
      # the page is UTF-8 when its bytes are, else WHATWG's legacy fallback,
      # windows-1252 — never nokogiri's ISO-8859-1 default, which made every
      # undeclared UTF-8 page mojibake.
      def markdown(html, charset: nil)
        input = html
        cut = nil
        if input.bytesize > RENDER_INPUT_BYTES
          input = input.byteslice(0, RENDER_INPUT_BYTES)
          cut = RENDER_INPUT_BYTES
        end
        document =
          if input.b.start_with?(*BYTE_ORDER_MARKS)
            Nokogiri::HTML5(input)
          else
            Nokogiri::HTML5(decode(input, page_encoding(input, charset)), nil, Encoding::UTF_8.name)
          end
        document.css(DROPPED).each(&:remove)
        title = clean(document.title.to_s).strip
        text = ReverseMarkdown.convert(document.root)
        Rendering.new(kind: :markdown, text: clean(text), title: title.empty? ? nil : title, cut: cut)
      rescue ArgumentError, EncodingError, Nokogiri::SyntaxError, ReverseMarkdown::Error => error
        raise Unrenderable, "the page could not be rendered (#{error.class.name.split("::").last})"
      end

      BYTE_ORDER_MARKS = ["\xEF\xBB\xBF".b, "\xFE\xFF".b, "\xFF\xFE".b].freeze
      # Both `<meta charset=x>` and the http-equiv `content="...; charset=x"`
      # spelling, as WHATWG's prescan reads them.
      META_CHARSET = /<meta[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_.:-]+)/i
      META_PRESCAN_BYTES = 1024
      LEGACY_FALLBACK = "Windows-1252".freeze

      def page_encoding(bytes, charset)
        encoding_name(charset) ||
          encoding_name(bytes.byteslice(0, META_PRESCAN_BYTES).b[META_CHARSET, 1]) ||
          (utf8_but_its_cut_tail?(bytes) ? Encoding::UTF_8.name : LEGACY_FALLBACK)
      end

      # Valid UTF-8, allowing only an incomplete last character: the render
      # bound can cut a page inside one, and that alone does not make it
      # another encoding. An invalid byte anywhere else does.
      def utf8_but_its_cut_tail?(bytes)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        return true if text.valid_encoding?

        kept = text.scrub("")
        kept.bytesize >= text.bytesize - 3 && text.b.start_with?(kept.b)
      end

      def encoding_name(charset)
        name = charset.to_s.strip
        return nil if name.empty?

        Encoding.find(name).name
      rescue ArgumentError
        nil
      end

      # Text under a declared charset is transcoded; anything else is read
      # as UTF-8 with invalid bytes replaced, never fatal (read's rule).
      def decode(bytes, charset)
        name = encoding_name(charset)
        if name && name != Encoding::UTF_8.name
          bytes.dup.force_encoding(name).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        else
          bytes.dup.force_encoding(Encoding::UTF_8).scrub
        end
      end

      def clean(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(INVISIBLE, "")
      end
    end
  end
end
