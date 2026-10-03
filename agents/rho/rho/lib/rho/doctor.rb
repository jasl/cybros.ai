require_relative "doctor/prerequisites"
require_relative "doctor/runtime"
require_relative "doctor/tools"
require_relative "doctor/environment"

module Rho
  # `rho doctor`: one table for a host after
  # install, the image at build (`--strict`) and the e2e install lane —
  # the prerequisites `install.sh` checked, the runtime it unpacked, every
  # tool row the receipt records, and the environment rho runs in. It
  # reads the receipt and the manifest (`Rho::Install`), never the network:
  # "a newer manifest exists" is `rho update`'s to find out.
  #
  # Without a prefix (a checkout under `bundle exec`) it still answers:
  # the prerequisite and environment rows are the same on both.
  module Doctor
    STATUSES = %i[ok warn fail].freeze
    Row = Data.define(:section, :name, :status, :detail) do
      def failed? = status == :fail
      def label = { ok: "ok  ", warn: "warn", fail: "FAIL" }.fetch(status)
    end

    # What every check reads: the environment, the prefix and its receipt
    # (nil outside an install), and the home when one resolves.
    Context = Data.define(:env, :prefix, :receipt, :home) do
      def installed? = !receipt.nil?
      def tool(name) = receipt&.dig("tools", name)
      def path(*segments) = File.join(prefix.to_s, *segments)
    end

    Report = Data.define(:context, :rows) do
      def failed? = rows.any?(&:failed?)

      def render
        lines = [heading]
        rows.each { |row| lines << format("  %s  %-16s %s", row.label, row.name, row.detail) }
        lines << summary
        lines.join("\n")
      end

      def heading
        receipt = context.receipt
        return "rho doctor: no RHO_PREFIX — a checkout; checking the environment alone" unless receipt

        commit = receipt.dig("app", "commit").to_s
        "rho doctor: #{context.prefix} (profile #{receipt["profile"]}, #{receipt["platform"]}, " \
          "rho #{receipt.dig("app", "version")}#{" at #{commit[0, 7]}" unless commit.empty?}, installed #{receipt["installed_at"]})"
      end

      def summary
        counts = rows.group_by(&:status).transform_values(&:length)
        "#{rows.length} rows: #{counts.fetch(:ok, 0)} ok, #{counts.fetch(:warn, 0)} warnings, " \
          "#{counts.fetch(:fail, 0)} failures"
      end
    end

    CHECKS = [Prerequisites, Runtime, Tools, Environment].freeze

    module_function

    def run(env: ENV, home: nil)
      context = Context.new(env: env, prefix: Rho::Install.prefix(env), receipt: Rho::Install.receipt(env), home: home)
      Report.new(context: context, rows: CHECKS.flat_map { |check| check.call(context) })
    end

    # A command's first output line, or nil when it is absent or fails.
    def version_line(*command)
      output = IO.popen(command, err: [:child, :out], &:read)
      $?&.success? ? output.to_s.lines.first.to_s.strip : nil
    rescue SystemCallError
      nil
    end

    # The executable `name` resolves to on `path` (a PATH string), or nil.
    # Resolved here, not by `popen`: Ruby searches the parent's own PATH
    # whatever env a child is handed, so a row about what is on the
    # context's PATH has to look for itself.
    def on_path(name, path)
      path.to_s.split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end
  end
end
