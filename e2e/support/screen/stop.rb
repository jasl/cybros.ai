require "time"

module E2E
  module Screen
    # A SCREEN'S REGISTERED STOP: one line in `<home>/logs/STOPPED`, `<time> <reason>`, the reason's
    # first word its class (`WatchRules`). Whoever stops the screen records it — the watch, the launch
    # on its own fault or a signal, the launch over a dead watch — and the first recorded wins, so a
    # stop is never overwritten by the exits it caused. Nothing starts after it, the analysis writes it
    # in place of a verdict, and a relaunch reads it when no readout holds the launch.
    module Stop
      module_function

      def path(home) = File.join(home, "logs", "STOPPED")

      # Whether this stop was recorded: false when an earlier one already stands.
      def record(home, reason, at: Time.now.utc)
        File.write(path(home), "#{at.iso8601} #{reason}\n", mode: "wx", encoding: Encoding::UTF_8)
        true
      rescue Errno::EEXIST
        false
      end

      # The recorded reason, or nil when the screen was not stopped.
      def reason(home)
        File.read(path(home), encoding: Encoding::UTF_8).strip.split(" ", 2).last if File.exist?(path(home))
      end

      def kind(reason) = reason.split(" ", 2).first
    end
  end
end
