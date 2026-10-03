require "openssl"
require_relative "../boot"

module Rho
  module Doctor
    # The runtime rows: the Ruby rho runs on against the receipt's, the
    # bundler the lock names against the one that loaded (a mismatch is a re-exec or a silent version flip), the gems, the
    # (ruby, gems) pair `current` points at, the TLS trust store, the
    # bootsnap cache, and the checkpoint stores under the home's work root.
    module Runtime
      # The trust store's two overrides, OpenSSL's own names, and how many
      # of a bundle's roots are tried against the default store.
      TRUST_FILE_ENV = "SSL_CERT_FILE".freeze
      TRUST_DIR_ENV = "SSL_CERT_DIR".freeze
      ROOTS_TRIED = 8

      module_function

      def call(context)
        rows = [ruby(context), bundler]
        rows << gems
        rows << pair(context) if context.installed?
        rows << tls(context)
        rows << bootsnap(context)
        rows << checkpoints(context.home) if context.home
        rows
      end

      # THE TRUST STORE: where this Ruby's OpenSSL reads its roots — SSL_CERT_FILE when set
      # (the wrapper bakes the host's bundle when the portable OpenSSL's compiled path, its
      # builder's Cellar, is absent), else that compiled path, else the cert dir — and that a
      # store built the way every client builds one (`set_default_paths`) trusts a root from
      # there. OFFLINE: a root is self-signed, so `verify` against the store is the proof,
      # never a connection. Under the prefix's Ruby the extension must be the Ruby's own: a
      # copy the bundle built beside the static OpenSSL is the defect itself (bundler installs
      # a default gem the lock pins unless `--prefer-local`), and no cert path cures it.
      def tls(context)
        extension = openssl_extension
        if context.installed? && prefix_ruby?(context) && !openssl_own?
          return Row.new("runtime", "tls", :fail, "#{extension}: a copy the bundle built beside the portable Ruby's static OpenSSL " \
            "cannot verify a certificate — reinstall (install.sh bundles with --prefer-local)")
        end

        path, source, roots = trust_store(context.env)
        return Row.new("runtime", "tls", :fail, "#{path} (#{source}) holds no root: Ruby-side HTTPS verifies nothing " \
          "(install ca-certificates; the wrapper names the host's bundle at the next install); #{extension}") if roots.empty?

        store = OpenSSL::X509::Store.new
        store.set_default_paths
        return Row.new("runtime", "tls", :fail, "#{path} (#{source}, #{roots_word(roots)}) but the default store trusts none of " \
          "the first #{ROOTS_TRIED}; #{extension}") unless roots.first(ROOTS_TRIED).any? { |root| store.verify(root) }

        Row.new("runtime", "tls", :ok, "#{path} (#{source}, #{roots_word(roots)}, the store trusts them); #{extension}")
      rescue OpenSSL::OpenSSLError, SystemCallError => error
        Row.new("runtime", "tls", :fail, "#{error.class}: #{error.message}; #{extension}")
      end

      # The loaded openssl gem is the Ruby's default gem (or none is loaded
      # yet), not a copy installed into a gem path.
      def openssl_own?
        spec = Gem.loaded_specs["openssl"]
        spec.nil? || spec.default_gem?
      end

      # `openssl <gem> (the Ruby's own)` or `openssl <gem> (from <gemspec>)`,
      # then the library the extension was built against.
      def openssl_extension
        origin = openssl_own? ? "the Ruby's own" : "from #{Gem.loaded_specs["openssl"].loaded_from}"
        "openssl #{OpenSSL::VERSION} (#{origin}), #{OpenSSL::OPENSSL_LIBRARY_VERSION}"
      end

      def roots_word(roots) = "#{roots.length} root#{"s" unless roots.length == 1}"

      # The path OpenSSL reads, where it came from, and the roots parsed
      # there: the file (the env's, else the compiled default), falling back
      # to the hashed dir (the env's, else the compiled default) when the
      # file is unreadable — the two lookups `set_default_paths` installs.
      def trust_store(env)
        file = env[TRUST_FILE_ENV].to_s
        file_source = file.empty? ? "OpenSSL's compiled path" : TRUST_FILE_ENV
        file = OpenSSL::X509::DEFAULT_CERT_FILE if file.empty?
        return [file, file_source, OpenSSL::X509::Certificate.load_file(file)] if File.readable?(file)

        dir = env[TRUST_DIR_ENV].to_s
        dir_source = dir.empty? ? "OpenSSL's compiled dir" : TRUST_DIR_ENV
        dir = OpenSSL::X509::DEFAULT_CERT_DIR if dir.empty?
        pems = File.directory?(dir) ? Dir.glob(File.join(dir, "*.{pem,crt,0}")).sort.first(ROOTS_TRIED) : []
        return [file, file_source, []] if pems.empty?

        [dir, dir_source, pems.flat_map { |pem| OpenSSL::X509::Certificate.load_file(pem) }]
      end

      # The receipt's ruby/current is what this process runs on (the
      # wrapper's case; a checkout's suite reading a fabricated prefix is not).
      def prefix_ruby?(context)
        RbConfig.ruby.start_with?("#{real(context.path("ruby"))}/")
      end

      # THE SHADOW STORES: every `<work>/checkpoints/<digest>/`
      # the daemon opened, their records counted by the store's own read
      # (`Store.record_count`: through git — the refs may be packed after
      # a prune — under its clock and neutral environment, never an open)
      # and the bytes they hold — the one place a person sees what the
      # work root carries for rewind.
      def checkpoints(home)
        dir = File.join(home.work_root, Rho::Runner::Checkpoints::Store::DIRECTORY)
        stores = File.directory?(dir) ? Dir.children(dir).sort.select { |child| File.directory?(File.join(dir, child)) } : []
        return Row.new("checkpoints", "store", :ok, "#{dir}: none yet") if stores.empty?

        records = stores.sum { |store| Rho::Runner::Checkpoints::Store.record_count(File.join(dir, store)) }
        stores_word = "#{stores.length} store#{"s" unless stores.length == 1}"
        records_word = "#{records} record#{"s" unless records == 1}"
        Row.new("checkpoints", "store", :ok, "#{dir}: #{stores_word}, #{records_word}, #{size_of(dir)}")
      end

      def ruby(context)
        description = RUBY_DESCRIPTION.split(" [").first
        return Row.new("runtime", "ruby", :ok, "#{description} (a checkout's)") unless context.installed?

        expected = context.receipt.dig("ruby", "version").to_s
        current = link_target(context.path("ruby", "current"))
        if current == expected && RbConfig.ruby.start_with?("#{real(context.path("ruby"))}/")
          Row.new("runtime", "ruby", :ok, "#{expected}: #{description}")
        elsif current != expected
          Row.new("runtime", "ruby", :fail, "ruby/current is #{current.inspect}, the receipt says #{expected}")
        else
          Row.new("runtime", "ruby", :fail, "running #{RbConfig.ruby}, not the prefix's ruby/current")
        end
      end

      def bundler
        return Row.new("runtime", "bundler", :warn, "not loaded") unless defined?(::Bundler::VERSION)

        locked = locked_bundler
        if locked.nil? || locked == ::Bundler::VERSION
          Row.new("runtime", "bundler", :ok, "#{::Bundler::VERSION} (the lock's)")
        else
          Row.new("runtime", "bundler", :fail, "#{::Bundler::VERSION} loaded, the lock says #{locked}")
        end
      end

      def locked_bundler
        lock = File.join(Rho.root, "Gemfile.lock")
        return nil unless File.file?(lock)

        File.read(lock, encoding: "UTF-8")[/^BUNDLED WITH\n\s+(\S+)/, 1]
      end

      def gems
        return Row.new("runtime", "gems", :warn, "bundler not loaded") unless defined?(::Bundler) && ::Bundler.respond_to?(:definition)

        missing = ::Bundler.definition.missing_specs
        return Row.new("runtime", "gems", :ok, "#{::Bundler.definition.specs.length} in the bundle") if missing.empty?

        Row.new("runtime", "gems", :fail, "missing: #{missing.map(&:full_name).join(", ")}")
      rescue StandardError => error
        Row.new("runtime", "gems", :fail, "#{error.class}: #{error.message}")
      end

      # `versions/<name>/.ruby` names the Ruby its vendor/bundle was compiled
      # against; `ruby/current` must be that one (update and rollback move
      # both links together).
      def pair(context)
        current = link_target(context.path("current"))
        return Row.new("runtime", "current", :fail, "no `current` link") if current.nil?

        marker = File.join(context.path("current"), ".ruby")
        built_against = File.file?(marker) ? File.read(marker).strip : nil
        ruby = link_target(context.path("ruby", "current"))
        if built_against && built_against == ruby
          Row.new("runtime", "current", :ok, "#{File.basename(current)} on ruby #{ruby}")
        else
          Row.new("runtime", "current", :fail,
            "#{File.basename(current)} was built against #{built_against.inspect}, ruby/current is #{ruby.inspect}")
        end
      end

      # The cache root, its size, and the key directories that are not
      # this Ruby's (bootsnap never cleans; `rm -rf` of the root is safe).
      def bootsnap(context)
        return Row.new("runtime", "bootsnap", :ok, "off (#{Rho::Boot::OFF_SWITCH})") if Rho::Boot.off?(context.env)

        root = Rho::Boot.cache_root(context.env)
        return Row.new("runtime", "bootsnap", :warn, "no cache yet under #{root}") unless File.directory?(root)

        key = Rho::Boot.key
        keys = Dir.children(root).select { |child| File.directory?(File.join(root, child)) }
        stale = keys - [key]
        detail = "#{root}: #{size_of(root)}"
        return Row.new("runtime", "bootsnap", :ok, detail) if stale.empty?

        Row.new("runtime", "bootsnap", :warn, "#{detail}, #{stale.length} stale key dir(s) — rm -rf #{root} to prune")
      end

      def size_of(root)
        bytes = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sum { |path| File.file?(path) ? File.size(path) : 0 }
        format("%.1f MB", bytes / 1_000_000.0)
      end

      # RbConfig.ruby is resolved; the prefix may be spelled through a
      # symlink (macOS's /var → /private/var).
      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def link_target(path)
        File.symlink?(path) ? File.basename(File.readlink(path)) : nil
      rescue SystemCallError
        nil
      end
    end
  end
end
