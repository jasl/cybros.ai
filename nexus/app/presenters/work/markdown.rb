module Work
  class Markdown
    # GFM owns syntax; raw HTML and Kramdown extensions are data, never
    # browser markup or converter options supplied by model/tool content.
    class Parser < Kramdown::Parser::GFM
      def initialize(source, options)
        super
        @block_parsers -= %i[block_html block_extensions block_math footnote_definition abbrev_definition]
        @span_parsers -= %i[span_extensions inline_math footnote_marker smart_quotes]
      end

      def parse_span_html
        add_text(@src.getch)
      end

      # Keep task-list markers as text rather than emitting form controls.
      def parse_list
        Kramdown::Parser::Kramdown.instance_method(:parse_list).bind_call(self)
      end
    end

    class Converter < Kramdown::Converter::Html
      def convert_img(element, _indent)
        label = escape_html(element.attr.fetch("alt", "").presence || element.attr.fetch("src"))
        href = escape_html(element.attr.fetch("src"), :attribute)
        "<a href=\"#{href}\">#{label}</a>"
      end
    end

    def self.render(source)
      options = { auto_ids: false, hard_wrap: false,
        syntax_highlighter: nil, math_engine: nil, template: "", header_offset: 1,
        gfm_quirks: %i[paragraph_end no_auto_typographic] }
      root, = Parser.parse(source, options)
      Converter.convert(root, options).first
    end
  end
end
