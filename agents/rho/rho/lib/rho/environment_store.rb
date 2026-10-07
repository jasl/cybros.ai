module Rho
  # WHERE THIS MACHINE'S TOOLS ARE POINTED, when somebody pointed them at
  # runtime rather than in a settings file.
  #
  # TWO FILES, TWO OWNERS, and that is the whole reason this is not just
  # another settings key. `settings.json` is the operator's — the daemon
  # reads it and never writes it, which is what makes it safe to hand-edit
  # while a daemon is running. This file is the DAEMON's: it is what the
  # API wrote, so it must survive a restart without the daemon ever
  # editing a file a human also edits.
  #
  # PRECEDENCE, and it reads the way people expect: what somebody set
  # through the API wins over what the settings file says, because setting
  # it was the later and more deliberate act. Clearing it falls back to
  # the settings, then to the daemon's own work root.
  class EnvironmentStore
    Selection = Data.define(:root, :source) do
      # `settings` and `default` are not the same answer even when they
      # produce the same path: one is a statement somebody made and one is
      # what happens when nobody did. A UI showing "where am I pointed"
      # needs to tell those apart.
      def stated? = source != "default"
    end

    def initialize(path)
      @file = StateFile.new(path)
    end

    def read
      document = @file.read
      return nil unless document.is_a?(Hash)

      value = document["root"].to_s
      value.empty? ? nil : value
    end

    def write(root)
      @file.write("root" => File.expand_path(root.to_s))
      self
    end

    def clear
      @file.delete
      self
    end

    # The one place the three sources are ordered, so nothing else has to
    # remember which wins.
    #
    # THE FALLBACK IS A BLOCK because computing it can fail: the daemon's
    # own work root needs an identity, and a daemon nobody has connected
    # has none. Passed as a value it was evaluated before this method
    # could see that a stored root made it unnecessary, so the cheapest
    # case raised on behalf of the most expensive one.
    def select(configured:)
      stored = read
      return Selection.new(root: stored, source: "api") if stored
      return Selection.new(root: configured, source: "settings") if configured

      Selection.new(root: yield, source: "default")
    end
  end
end
