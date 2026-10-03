require "rbconfig"
require "shellwords"

module Rho
  module Cli
    # THE ONE BROWSER LAUNCHER: `rho console
    # --open` and `rho mcp login` both hand a person a URL that is ALREADY
    # on screen, then try to open it — never fatal, because launching a
    # browser is a portability tax on the headless boxes a wider bind
    # exists for. `$BROWSER`, when set, is the opener (the xdg / Python
    # `webbrowser` convention): split as a shell would, the URL put in
    # place of `%s` when the command carries one, appended otherwise —
    # which is also how a harness stubs the browser. Without it, `open` on
    # darwin and `xdg-open` elsewhere. Detached: the opener's exit is not
    # this verb's.
    module Browser
      DARWIN = /darwin/
      URL_SLOT = "%s".freeze

      module_function

      # Answers whether an opener was launched; prints the reason otherwise.
      def launch(url, env: ENV, out: $stdout)
        Process.detach(Process.spawn(*command(url, env: env), out: File::NULL, err: File::NULL))
        true
      rescue StandardError => error
        out.puts "(could not launch a browser: #{error.class} — the URL above still works)"
        false
      end

      # The argv an opener runs with, pure: `$BROWSER` with the URL in its
      # `%s` slot or appended, else the platform's opener and the URL.
      def command(url, env: ENV, host_os: RbConfig::CONFIG["host_os"])
        browser = env["BROWSER"].to_s
        return [host_os.match?(DARWIN) ? "open" : "xdg-open", url] if browser.strip.empty?

        words = Shellwords.split(browser)
        return words.map { |word| word.gsub(URL_SLOT, url) } if words.any? { |word| word.include?(URL_SLOT) }

        words + [url]
      end
    end
  end
end
