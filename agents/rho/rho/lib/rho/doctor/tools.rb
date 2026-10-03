module Rho
  module Doctor
    # Every tool row the receipt records: the binary
    # is where the layout puts it and answers its version. Node lives under
    # `lib/playwright/node` (never in `bin/`, so a project's Node is
    # untouched); playwright-core is a package, checked against the gem's
    # `COMPATIBLE_PLAYWRIGHT_VERSION`; the Chromium shell is a directory
    # Playwright downloaded (HTTPS-only, the one unpinned row).
    module Tools
      module_function

      def call(context)
        return [] unless context.installed?

        context.receipt.fetch("tools", {}).map do |name, row|
          case name
          when "node" then node(context, row)
          when "playwright-core" then playwright(context, row)
          when "chromium" then chromium(context)
          else binary(context, name, row)
          end
        end
      end

      def binary(context, name, row)
        path = context.path("bin", name)
        expected = row["version"].to_s
        return Row.new("tools", name, :fail, "#{path} is missing") unless File.executable?(path)

        line = Doctor.version_line(path, "--version")
        return Row.new("tools", name, :ok, "#{expected} (#{path})") if line&.include?(expected)

        Row.new("tools", name, :fail, "#{path} answers #{line.inspect}, the receipt says #{expected}")
      end

      def node(context, row)
        path = context.path("lib", "playwright", "node", "bin", "node")
        return Row.new("tools", "node", :fail, "#{path} is missing") unless File.executable?(path)

        line = Doctor.version_line(path, "--version")
        return Row.new("tools", "node", :ok, "#{row["version"]} (the driver's, not on PATH)") if line == "v#{row["version"]}"

        Row.new("tools", "node", :fail, "#{path} answers #{line.inspect}, the receipt says #{row["version"]}")
      end

      def playwright(context, row)
        package = context.path("lib", "playwright", "package", "package.json")
        return Row.new("tools", "playwright-core", :fail, "#{package} is missing") unless File.file?(package)

        installed = JSON.parse(File.read(package))["version"].to_s
        compatible = gem_playwright_version
        if installed != row["version"].to_s
          Row.new("tools", "playwright-core", :fail, "#{installed} unpacked, the receipt says #{row["version"]}")
        elsif compatible && compatible != installed
          Row.new("tools", "playwright-core", :fail, "#{installed} unpacked, the gem wants #{compatible}")
        else
          Row.new("tools", "playwright-core", :ok, "#{installed}#{compatible ? " = the gem's" : ""}")
        end
      rescue JSON::ParserError
        Row.new("tools", "playwright-core", :fail, "#{package} is not JSON")
      end

      def gem_playwright_version
        require "playwright/version"
        ::Playwright::COMPATIBLE_PLAYWRIGHT_VERSION
      rescue LoadError, NameError
        nil
      end

      def chromium(context)
        browsers = context.path("browsers")
        shells = Dir.glob(File.join(browsers, "chromium*")).map { |path| File.basename(path) }
        return Row.new("tools", "chromium", :ok, shells.join(", ")) unless shells.empty?

        Row.new("tools", "chromium", :fail, "no chromium under #{browsers}: run `#{context.path("bin", "rho-playwright")} install --only-shell chromium`")
      end
    end
  end
end
