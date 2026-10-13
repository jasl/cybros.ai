require "json"

module Rho
  # THE INSTALLED PREFIX: what `install/install.sh`
  # leaves behind and what the verbs that outlive an install read from it —
  # the receipt (`receipt.json`: profile, platform, every row's version and
  # sha, the checkout's commit as `app.commit`, the (ruby, gems) pair
  # `current` points at), the manifest the install came from, and
  # `libexec/install.sh`, the copy `rho update` and `rho uninstall` exec
  # (`update` pulls the checkout the receipt names, then runs THAT checkout's installer — the rolling update).
  #
  # The wrapper `bin/rho` exports `RHO_PREFIX`; a checkout run under
  # `bundle exec` has none and is not an install: `update` and `uninstall`
  # refuse there — that checkout IS the developer's `git pull` — and
  # `doctor` checks the environment alone. The prefix is also
  # a protected root (`Rho.protected_roots`): the wrapper, the portable
  # Ruby, `vendor/bundle` and the installer are never a model's to write.
  module Install
    PREFIX_ENV = "RHO_PREFIX".freeze
    RECEIPT = "receipt.json".freeze
    MANIFEST = "manifest.json".freeze
    INSTALLER = File.join("libexec", "install.sh").freeze
    BASH = "/bin/bash".freeze

    module_function

    # The prefix the wrapper exported, expanded; nil when unset or empty.
    def prefix(env = ENV)
      value = env[PREFIX_ENV].to_s
      value.strip.empty? ? nil : File.expand_path(value)
    end

    def installed?(env = ENV)
      !prefix(env).nil? && File.file?(receipt_path(env))
    end

    def receipt_path(env = ENV) = File.join(prefix(env).to_s, RECEIPT)
    def manifest_path(env = ENV) = File.join(prefix(env).to_s, MANIFEST)
    def installer_path(env = ENV) = File.join(prefix(env).to_s, INSTALLER)

    # The receipt as a Hash, or nil: no prefix, no file, or not JSON.
    def receipt(env = ENV) = document(receipt_path(env), env)
    def manifest(env = ENV) = document(manifest_path(env), env)

    def document(path, env)
      return nil if prefix(env).nil? || !File.file?(path)

      parsed = JSON.parse(File.read(path, encoding: "UTF-8"))
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # The prefix as a protected root: its resolved spelling when it exists.
    def protected_root(env = ENV)
      path = prefix(env)
      path && File.directory?(path) ? File.realpath(path) : nil
    end

    # `rho update` / `rho uninstall`: thin verbs that replace this process
    # with the installer in the named mode. Refused outside an install —
    # a checkout under `bundle exec` is rolled by `git pull` and installed
    # by its own `install/install.sh`.
    def exec_installer(mode, *arguments, env: ENV)
      unless installed?(env)
        raise Rho::ConfigurationError,
          "not an installed rho (RHO_PREFIX is unset or has no receipt); a checkout is rolled with `git pull` " \
          "and installed by its own `install/install.sh` (which then owns `rho update`)"
      end

      installer = installer_path(env)
      raise Rho::ConfigurationError, "#{installer} is missing; re-run install.sh" unless File.file?(installer)

      Kernel.exec(BASH, installer, mode, *arguments)
    end
  end
end
