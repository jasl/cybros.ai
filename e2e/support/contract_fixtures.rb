require "json"

module E2E
  # The checked-in contract fixture pack: nexus generates and drift-checks `contracts/nexus/v1`;
  # this harness verifies the manifest and consumes fixtures without copying their values inline.
  module ContractFixtures
    ROOT = File.expand_path("../../contracts/nexus/v1", __dir__)
    CONTRACT = "nexus/v1".freeze

    @packs = {}

    class << self
      def validate!
        return true if @validated

        validate_version!(
          meta_contract: meta.fetch("contract"),
          manifest_contract: manifest.fetch("contract")
        )

        # The manifest's file list is what the directory cannot tell us: that
        # the set is COMPLETE. It carries no digests — the pack's authority is
        # the generator, and Nexus::ContractTest compares every committed byte
        # against freshly rendered output in the same CI run.
        expected_files = Dir.glob(File.join(ROOT, "*.json"))
          .map { |path| File.basename(path) }
          .reject { |name| name == "manifest.json" }
          .sort
        unless manifest.fetch("files").sort == expected_files
          raise ArgumentError, "Nexus contract fixture manifest is incomplete"
        end

        @validated = true
      end

      def validate_version!(meta_contract:, manifest_contract:)
        unless meta_contract == CONTRACT && manifest_contract == CONTRACT
          raise ArgumentError, "unsupported Nexus contract fixture version"
        end

        true
      end

      def meta
        load_pack("meta.json")
      end

      def coverage
        load_pack("coverage.json")
      end

      def workspaces
        load_pack("workspaces.json")
      end

      def store_entries
        load_pack("store_entries.json")
      end

      def errors
        load_pack("errors.json")
      end

      def oauth
        load_pack("oauth.json")
      end

      def profiles
        load_pack("profiles.json")
      end

      def sessions
        load_pack("sessions.json")
      end

      def admin_users
        load_pack("admin_users.json")
      end

      def agent_loops
        load_pack("agent_loops.json")
      end

      # The executor plane's inbox and its commit grammar.
      def executor_inbox
        load_pack("executor_inbox.json")
      end

      # The upload doors and the one bytes read.
      def uploads
        load_pack("uploads.json")
      end

      # The model plane: the account's listing and its provider lanes.
      def models
        load_pack("models.json")
      end

      # The executor's self-read and the member plane's discovery.
      def task_executors
        load_pack("task_executors.json")
      end

      def conversations
        load_pack("conversations.json")
      end

      # A JSON pointer, walked the way the spec defines it: a segment
      # against an Array is an INDEX. THE THIRD COPY of this walker — nexus
      # and the SDK carry the other two — and all three were Hash-only
      # until a contract pointed at a fixture inside a list.
      def resolve(reference)
        name, pointer = reference.split("#", 2)
        pointer.to_s.split("/").reject(&:empty?)
          .reduce(load_pack(name)) do |value, key|
            value.is_a?(Array) ? value.fetch(Integer(key, 10)) : value.fetch(key)
          end
      end

      private

      def manifest
        load_pack("manifest.json")
      end

      def load_pack(name)
        # Named UTF-8: this machine has no LANG, and the pack carries the
        # kernel tools' own prose.
        @packs[name] ||= JSON.parse(File.read(File.join(ROOT, name), encoding: Encoding::UTF_8)).freeze
      end
    end
  end
end
