require "json"

module CybrosAgentTest
  # Test-only reader for the Nexus-owned pack. It verifies integrity and
  # version before exposing only contracts consumed by the public gem.
  module ContractFixtures
    ROOT = File.expand_path("../../../../contracts/nexus/v1", __dir__)
    CONTRACT = "nexus/v1".freeze
    SDK_FILES = %w[
      coverage.json
      credentials.json
      errors.json
      meta.json
      oauth.json
      profiles.json
      task_executors.json
      executor_inbox.json
      uploads.json
      one_shots.json
      conversations.json
      scheduled_jobs.json
      history.json
      agent_loops.json
      store_entries.json
      prompt_documents.json
      memory_documents.json
      workspaces.json
      tools.json
      models.json
      size_bounds.json
      content_addressing.json
    ].freeze

    class << self
      def validate!
        validate_version!(
          meta_contract: raw_pack("meta.json").fetch("contract"),
          manifest_contract: manifest.fetch("contract")
        )

        # The manifest's file list proves the set is COMPLETE, which the
        # directory cannot say for itself. It carries no digests — the pack's
        # authority is the generator, and Nexus's own contract test compares
        # every committed byte against freshly rendered output in the same CI
        # run.
        expected_files = Dir.glob(File.join(ROOT, "*.json"))
          .map { |path| File.basename(path) }
          .reject { |name| name == "manifest.json" }
          .sort
        unless manifest.fetch("files").sort == expected_files
          raise ArgumentError, "incomplete contract fixture manifest"
        end

        true
      end

      def validate_version!(meta_contract:, manifest_contract:)
        unless meta_contract == CONTRACT && manifest_contract == CONTRACT
          raise ArgumentError, "unsupported Nexus contract fixture version"
        end

        true
      end

      def pack(name)
        raise ArgumentError, "contract is not consumed by CybrosAgent: #{name}" unless SDK_FILES.include?(name)

        validate!
        raw_pack(name)
      end

      # A JSON pointer, walked the way the spec defines it: a segment
      # against an Array is an INDEX. The walker was Hash-only until a
      # contract pointed at a fixture inside a list, which is where the
      # conversation plane's vocabularies live — its turns and events are
      # published as one-element pages rather than as bare objects.
      def resolve(reference)
        name, pointer = reference.split("#", 2)
        pointer.to_s.split("/").reject(&:empty?)
          .reduce(pack(name)) do |value, key|
            value.is_a?(Array) ? value.fetch(Integer(key, 10)) : value.fetch(key)
          end
      end

      private

      def manifest
        raw_pack("manifest.json")
      end

      def raw_pack(name)
        # Named UTF-8: this machine has no LANG, and the pack carries the
        # kernel tools' own prose.
        JSON.parse(File.read(File.join(ROOT, name), encoding: Encoding::UTF_8))
      end
    end
  end
end
