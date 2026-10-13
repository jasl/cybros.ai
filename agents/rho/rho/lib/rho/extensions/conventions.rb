require_relative "../conventions"

module Rho
  module Extensions
    # AGENTS.md and CLAUDE.md from the work directory up to the root, then
    # the home's `AGENTS.md` (the daemon's `$RHO_HOME`; a standalone runner
    # has no home and reads the walk alone), read once at authoring and
    # carried byte-identically by every continuation. Registered after
    # Processes so the seed's bytes keep their order.
    module Conventions
      NAME = "rho.conventions".freeze
      # THE ONE SENTENCE WHILE A PORT IS LIVE: the editor's buffers are what
      # `read`, `edit` and `write` see through the file-system port, the
      # disk is what everything else sees, and no rule reconciles the two
      # after a shell write — so the model is told, once, on the lead of
      # every turn whose anchor has a live port. The model-facing instruction,
      # benched at the paid window, never hand-tuned in a fix.
      PORT_SENTENCE = "The editor's open buffers are what read, edit and write see; grep, glob, ls and shell " \
                      "commands see the disk — use edit or write for files open in the editor; a shell write to a " \
                      "file with unsaved changes is invisible to read.".freeze

      def self.register(api)
        home = api.host&.home&.root
        # The daemon's environment tables, late-bound (`member_plane`'s
        # precedent): the lead being rendered names its anchor there; nil
        # under a loader with no daemon, which has no port to speak of.
        environments = api.host&.environments
        api.describe_environment do |environment|
          block = Rho::Conventions.block(
            working_directory: environment.working_directory || environment.root,
            root: environment.root, home: home
          )
          sentence = PORT_SENTENCE if environments&.call&.lead_port?
          parts = [block, sentence].compact
          parts.empty? ? nil : parts.join("\n\n")
        end
      end
    end
  end
end
