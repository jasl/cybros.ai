module Rho
  # A UTF-8 LOCALE FOR EVERY PROCESS THIS DAEMON SPAWNS, when the one that
  # launched it set none.
  #
  # The daemon's own encoding is fixed at boot in `exe/rho`; that line does
  # nothing for the processes the model's tools start — `ruby`, `git`,
  # `python`, anything a `bash` call runs — which inherit the environment
  # and derive THEIR default encoding from it. On this machine the shell
  # sets no LANG, and neither does launchd or systemd, so every such child
  # started as US-ASCII and the first non-ASCII byte it read was an
  # exception or a silently mangled string.
  #
  # THE NAME MUST BE VALID, which is why it is `C.UTF-8` and not `en_US`:
  # a locale the system does not have makes `setlocale` fail and the
  # process fall back to "C" — US-ASCII again, with no error — so a wrong
  # guess is worse than no default. `C.UTF-8` is built into glibc (2.35+),
  # musl and macOS 13+ without a locale-gen step; `en_US.UTF-8` is not.
  #
  # ONLY WHEN NOTHING IS SET. An operator who chose a locale — any of the
  # three variables that govern the character type — chose it, and this
  # neither overrides nor second-guesses it, even if it is not UTF-8.
  module Locale
    DEFAULT = "C.UTF-8".freeze
    GOVERNING = %w[LC_ALL LC_CTYPE LANG].freeze

    module_function

    # Answers what it set: `{"LANG" => "C.UTF-8"}` when it defaulted, an
    # empty Hash when the environment already had a say. `env` is an ENV
    # or any Hash-like that answers `[]` and `[]=` — a test hands a Hash.
    def ensure_utf8!(env = ENV)
      return {} if GOVERNING.any? { |name| !env[name].to_s.empty? }

      env["LANG"] = DEFAULT
      { "LANG" => DEFAULT }
    end
  end
end
