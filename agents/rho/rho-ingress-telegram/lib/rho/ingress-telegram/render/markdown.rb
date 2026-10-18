require "kramdown"
require "kramdown-parser-gfm"
require "uri"

module Rho
  module IngressTelegram
    module Render
      # Only the Markdown grammar comes from kramdown. HTML and its configuration
      # extensions stay literal; no converter, template, or highlighting code runs.
      class Markdown < Kramdown::Parser::GFM
        def initialize(source, options)
          super
          @block_parsers -= %i[block_html block_extensions block_math footnote_definition abbrev_definition]
          @span_parsers -= %i[span_extensions inline_math footnote_marker smart_quotes]
        end

        # Table parsing names this parser explicitly, so retain its registration.
        def parse_span_html
          add_text(@src.getch)
        end

        # GFM's task-list renderer injects HTML checkboxes during parsing. Keep the
        # original [x]/[ ] text because Telegram has no checkbox entity.
        def parse_list
          Kramdown::Parser::Kramdown.instance_method(:parse_list).bind_call(self)
        end
      end

      Span = Data.define(:text, :tags)

      class Document
        def initialize(source)
          @trailing_newlines = source[/\n*\z/]
          @root, = Markdown.parse(source, auto_ids: false, hard_wrap: false,
            gfm_quirks: %i[paragraph_end no_auto_typographic])
          @spans = []
        end

        def spans
          blocks(@root.children)
          ending = @spans.last&.text.to_s[/\n*\z/]
          append("\n" * (@trailing_newlines.length - ending.length)) if @trailing_newlines.length > ending.length
          @spans
        end

        private

          def append(text, tags = [])
            @spans << Span.new(text: text, tags: tags) unless text.empty?
          end

          def blocks(elements, tags = [])
            elements.reject { |element| element.type == :blank }.each_with_index do |element, index|
              append("\n\n") if index.positive?
              render(element, tags)
            end
          end

          def children(element, tags)
            element.children.each { |child| render(child, tags) }
          end

          def styled(element, tags, name)
            children(element, (tags + [["<#{name}>", "</#{name}>"]]).uniq)
          end

          def render(element, tags)
            case element.type
            when :text then append(element.value, tags)
            when :entity then append(element.value.char, tags)
            when :p, :root, :li, :dd then children(element, tags)
            when :strong, :header, :dt then styled(element, tags, "b")
            when :em then styled(element, tags, "i")
            when :html_element # Raw HTML parsing is disabled; GFM emits only del.
              styled(element, tags, "s")
            when :codespan then append(element.value, [["<code>", "</code>"]])
            when :codeblock then codeblock(element)
            when :a then link(element, tags)
            when :img then append("#{element.attr.fetch("alt", "")} (#{element.attr.fetch("src")})", tags)
            when :ul, :ol then list(element, tags)
            when :blockquote then blocks(element.children, (tags + [["<blockquote>", "</blockquote>"]]).uniq)
            when :table then table(element, tags)
            when :hr then append("———", tags)
            when :br then append("\n", tags)
            when :blank then nil
            else
              # Unsupported structural features retain their text without adding
              # tags Telegram does not accept.
              element.children.empty? ? append(element.value.to_s, tags) : children(element, tags)
            end
          end

          def codeblock(element)
            language = element.options[:lang].to_s
            attribute = /\A[a-zA-Z0-9_+.-]{1,64}\z/.match?(language) ? " class=\"language-#{language}\"" : ""
            append(element.value, [["<pre><code#{attribute}>", "</code></pre>"]])
          end

          def link(element, tags)
            destination = element.attr.fetch("href")
            if safe_link?(destination)
              children(element, tags + [["<a href=\"#{Render.escape(destination)}\">", "</a>"]])
            else
              children(element, tags)
              append(" (#{destination})", tags)
            end
          end

          def safe_link?(destination)
            uri = URI.parse(destination)
            case uri.scheme
            when "http", "https" then !uri.host.to_s.empty? && uri.userinfo.nil?
            when "mailto" then !uri.opaque.to_s.empty?
            else false
            end
          rescue URI::InvalidURIError
            false
          end

          def list(element, tags)
            element.children.each_with_index do |item, index|
              append("\n", tags) if index.positive?
              marker = element.type == :ol ? "#{element.attr.fetch("start", 1).to_i + index}. " : "• "
              append(marker, tags)
              blocks(item.children, tags)
            end
          end

          def table(element, tags)
            rows = element.children.flat_map(&:children)
            rows.each_with_index do |row, index|
              append("\n", tags) if index.positive?
              row.children.each_with_index do |cell, column|
                append(" | ", tags) if column.positive?
                children(cell, tags)
              end
            end
          end
      end
    end
  end
end
