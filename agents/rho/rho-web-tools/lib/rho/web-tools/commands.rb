module Rho
  module WebTools
    # THE CLI: ONE verb, `rho web fetch URL [--raw]`. It
    # runs the client and the render in the CLI process against the
    # settings file's `web` table (the CLI ran `register(api)` to learn the
    # verb, so the module holds the judged settings), prints the status
    # line to stderr and the WHOLE rendering to stdout — no truncation and
    # no spill, because the cap is the MODEL's defence — with every
    # invisible byte escaped by default (what a model would read,
    # honestly; the render strips them, so a clean render prints clean),
    # `--raw` for the bytes as rendered (the journey's byte-equal pin); a
    # binary answer is its bytes to stdout, always raw (`rho fetch`'s
    # shape: whole, redirect it); a refusal is the sentence the model
    # would read, exit 1. No route: the daemon exposes no `GET /web`.
    module Commands
      USAGE = "web fetch URL [--raw]".freeze
      DESCRIPTION = "Fetch a URL from this process as web_fetch would and print what the model would read, whole: " \
                    "the status line on stderr, the rendering on stdout with every invisible byte escaped " \
                    "(--raw prints the bytes as rendered; a binary answer is its bytes, always raw)".freeze
      OPTIONS = { raw: { type: :boolean, default: false, desc: "Print the rendering's bytes as they are, unescaped" } }.freeze

      module_function

      def run(cli, args, options)
        case args
        in ["fetch", url] then fetch(cli, url, raw: options[:raw] == true)
        else refuse("usage: rho #{USAGE}")
        end
      end

      # A one-sentence refusal the CLI prints (`Rho::Error` where rho is
      # loaded — the only process with this verb; the gem's own root
      # otherwise, so nothing here names a constant rho-runner lacks).
      def refuse(sentence)
        raise (defined?(Rho::Error) ? Rho::Error : Rho::WebTools::Error), sentence
      end

      def fetch(cli, url, raw:)
        page = Client.new(allow_private_network: Rho::WebTools.allow_private_network?).get(UrlRule.parse(url))
        refuse(Tools::Fetch.answered(page)) if page.error? || page.redirect?

        rendering = Render.call(page)
        if rendering.kind == :bytes
          warn "#{page.final_url} — #{page.status} #{page.media_type}; #{Tools::Fetch.size(page.bytes)}"
          cli.out.write(page.body)
        else
          warn Tools::Fetch.status_line(page, rendering)
          cli.out.write(raw ? rendering.text : escape(rendering.text))
        end
        cli.out.flush
        page
      rescue Rho::WebTools::Error => error
        refuse(error.message)
      end

      # Every invisible or control character its `\u{…}` dump; a newline
      # and a tab print as themselves — the rendering is a page, not a
      # description line.
      def escape(text)
        text.to_s.gsub(Render::INVISIBLE) { |char| format("\\u{%X}", char.ord) }
      end
    end
  end
end
