module Rho
  class Runner
    # WHAT A CHILD PROCESS INHERITS, decided once for every spawn site.
    #
    # THE DAEMON RUNS UNDER BUNDLER, and Bundler's `bundle exec` leaves a
    # trail in the environment — BUNDLE_GEMFILE, BUNDLE_FROZEN, RUBYOPT's
    # `-rbundler/setup`, RUBYLIB, the bin path on PATH — that is meant for
    # THIS process and is poison for any other Ruby: `bin/rails server`
    # started from a tool would load rho's Gemfile.lock instead of the
    # project's and die with "Could not find gem 'rails'", a failure the
    # model cannot diagnose in a server it never sees. Bundler keeps the
    # environment it started from for exactly this hand-off, so that is
    # what a child gets; without Bundler loaded, the same keys are dropped
    # by name.
    #
    # THE LOCALE IS RE-APPLIED on top, because rho decides it AFTER Bundler
    # took its snapshot: a machine with no LANG at all gives every child a
    # US-ASCII world, and rho's fix for its own process must reach the
    # processes it starts.
    #
    # Python block-buffers stdout on a pipe; a server that is listening
    # prints nothing until it flushes, which reads as "not started". One
    # variable, harmless everywhere else.
    #
    # THE SCRUB (`scrubbed`)
    # is what a THIRD PARTY's long-lived process gets whole, under
    # `unsetenv_others: true` at its spawn site — an MCP server, an ACP
    # agent — REPLACED, never merged: `call` minus every credential-shaped
    # name (`Secrets::CREDENTIAL_SHAPED`: the person's `OPENAI_API_KEY`
    # is not the child's), minus rho's own (`RHO_*`), minus Bundler's
    # trail by name on top — `call` restores the environment Bundler
    # started from, which under a NESTED `bundle exec` (the harness's
    # rake around the daemon) is itself Bundler-shaped, and a third
    # party's Ruby must never load rho's lock. The row's own `env` lands
    # on top at the spawn site, which is how a child gets exactly the
    # credential the person wrote for it.
    module ChildEnv
      BUNDLER_KEYS = /\A(BUNDLE_|RUBYOPT\z|RUBYLIB\z|GEM_HOME\z|GEM_PATH\z)/
      LOCALE_KEYS = %w[LANG LC_ALL LC_CTYPE].freeze
      ADDITIONS = { "PYTHONUNBUFFERED" => "1" }.freeze
      RHO_PREFIX = "RHO_".freeze
      BUNDLER_PREFIX = "BUNDLER_".freeze

      module_function

      def call(current = ENV.to_h)
        base =
          if defined?(::Bundler) && ::Bundler.respond_to?(:with_unbundled_env)
            ::Bundler.with_unbundled_env { ENV.to_h }
          else
            current.reject { |key, _| key.match?(BUNDLER_KEYS) }
          end
        locale = current.slice(*LOCALE_KEYS)
        base.except(*LOCALE_KEYS).merge(locale).merge(ADDITIONS)
      end

      def scrubbed(current = ENV.to_h)
        call(current).reject do |name, _value|
          name.match?(Secrets::CREDENTIAL_SHAPED) || name.start_with?(RHO_PREFIX, BUNDLER_PREFIX) ||
            name.match?(BUNDLER_KEYS)
        end
      end
    end
  end
end
