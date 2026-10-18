module Work
  class MarkdownScrubber < Rails::HTML::PermitScrubber
    def initialize
      super
      self.tags = %w[p h2 h3 h4 h5 h6 ul ol li blockquote table thead tbody tr th td pre code em strong del a hr br]
      self.attributes = %w[href title start]
    end

    protected

      def scrub_attributes(node)
        super
        href = node["href"]
        return unless href

        # Rails removes encoded script protocols first; the console additionally
        # limits navigation to web, mail and ordinary relative references.
        scheme = URI.parse(URI::DEFAULT_PARSER.escape(href)).scheme
        node.remove_attribute("href") unless scheme.nil? || %w[http https mailto].include?(scheme.downcase)
      rescue URI::InvalidURIError
        node.remove_attribute("href")
      end
  end
end
