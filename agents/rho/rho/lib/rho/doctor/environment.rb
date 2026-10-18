module Rho
  module Doctor
    # The environment rows: the locale rho and its children run under, the
    # home (0700, the instance), the launcher on PATH, and the daemon.
    module Environment
      LAUNCHER = "rho".freeze

      module_function

      def call(context)
        rows = [locale(context.env), home(context.home)]
        rows << launcher(context) if context.installed?
        rows << daemon(context.home)
        rows
      end

      # `exe/rho` already ran `Rho::Locale.ensure_utf8!`, so a LANG here is
      # what every tool child inherits.
      def locale(env)
        governing = Rho::Locale::GOVERNING.filter_map { |name| "#{name}=#{env[name]}" unless env[name].to_s.empty? }
        return Row.new("environment", "locale", :fail, "none of LC_ALL LC_CTYPE LANG is set") if governing.empty?

        utf8 = governing.any? { |setting| setting.downcase.include?("utf-8") || setting.downcase.include?("utf8") }
        Row.new("environment", "locale", utf8 ? :ok : :warn, governing.join(" ") + (utf8 ? "" : " (not UTF-8)"))
      end

      def home(home)
        return Row.new("environment", "home", :warn, "no home resolved") if home.nil?

        root = home.root
        return Row.new("environment", "home", :warn, "#{root} does not exist yet (the first verb creates it)") unless File.directory?(root)

        mode = File.stat(root).mode & 0o777
        instance = File.file?(home.instance_path) ? "instance present" : "no instance.json yet (never booted)"
        if mode == Rho::Home::PRIVATE_DIRECTORY_MODE
          Row.new("environment", "home", :ok, "#{root} (0700, #{instance})")
        else
          Row.new("environment", "home", :warn, "#{root} is #{format("0%o", mode)}, rho narrows it to 0700 at boot; #{instance}")
        end
      end

      def launcher(context)
        recorded = context.receipt["launcher"].to_s
        return Row.new("environment", "launcher", :warn, "no launcher recorded") if recorded.empty?
        return Row.new("environment", "launcher", :fail, "#{recorded} is missing") unless File.exist?(recorded)

        found = on_path(context.env)
        return Row.new("environment", "launcher", :ok, recorded) if found && same?(found, recorded)

        Row.new("environment", "launcher", :warn,
          "#{recorded} is not on PATH#{found ? " (#{found} is)" : ""}: export PATH=\"#{File.dirname(recorded)}:$PATH\"")
      end

      # Bundler prepends the bundle's own bin dir to this process's PATH
      # (`vendor/bundle/ruby/<abi>/bin`, rho's binstub); that is not the
      # launcher a person's shell resolves.
      def on_path(env)
        env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |directory|
          next if directory.include?("/vendor/bundle/")

          candidate = File.join(directory, LAUNCHER)
          return candidate if File.executable?(candidate) && !File.directory?(candidate)
        end
        nil
      end

      def same?(left, right)
        File.realpath(left) == File.realpath(right)
      rescue SystemCallError
        false
      end

      def daemon(home)
        return Row.new("environment", "daemon", :warn, "no home resolved") if home.nil?
        return Row.new("environment", "daemon", :ok, "not running (no announcement)") unless File.file?(home.announcement_path)

        announced = JSON.parse(File.read(home.announcement_path))
        Row.new("environment", "daemon", :ok, "announced at #{announced["endpoint"] || home.announcement_path}")
      rescue JSON::ParserError, SystemCallError
        Row.new("environment", "daemon", :warn, "announcement present but unreadable")
      end
    end
  end
end
