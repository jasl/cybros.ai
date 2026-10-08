#!/usr/bin/env ruby
require "json"
require "open3"

# Registry checks for publish.sh. Docker owns registry transport and credentials;
# this helper only reads its JSON output and prints the verified image digest.
module ReleaseImages
  class << self
    def run(arguments)
      action = arguments.shift
      case action
      when "absent"
        arguments.each { |reference| assert_absent(reference) }
      when "native"
        reference, architecture, version, revision, source = arguments
        manifest = inspect_image(reference, "Manifest")
        entries = native_entries(manifest)
        digest = if entries
          assert_platforms(entries, ["linux/#{architecture}"], reference)
          entries.fetch(0).fetch("digest")
        else
          manifest.fetch("digest")
        end
        verify_config(reference, digest, architecture, version, revision, source)
        puts digest
      when "release"
        reference, version, revision, source, amd64_digest, arm64_digest, expected_digest = arguments
        manifest = inspect_image(reference, "Manifest")
        entries = native_entries(manifest) || []
        assert_platforms(entries, ["linux/amd64", "linux/arm64"], reference)
        expected = { "amd64" => amd64_digest, "arm64" => arm64_digest }
        entries.each do |entry|
          architecture = entry.fetch("platform").fetch("architecture")
          digest = entry.fetch("digest")
          unless digest == expected.fetch(architecture)
            abort "#{reference}: linux/#{architecture} differs from the checked native image"
          end
          verify_config(reference, digest, architecture, version, revision, source)
        end
        digest = manifest.fetch("digest")
        if expected_digest && digest != expected_digest
          abort "#{reference}: index digest differs from the verified release"
        end
        puts digest
      else
        abort "Usage: verify-release.rb absent REF... | native REF ARCH VERSION REVISION SOURCE | release REF VERSION REVISION SOURCE AMD64_DIGEST ARM64_DIGEST [INDEX_DIGEST]"
      end
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      abort "Registry inspection returned an incomplete or invalid image document."
    end

    private

    def assert_absent(reference)
      _output, errors, status = inspect_command(reference, "Manifest")
      if status.success?
        abort "#{reference} already exists; choose a new UTC minute tag."
      elsif !missing_manifest?(reference, errors)
        abort "Could not establish that #{reference} is absent: #{errors.strip}"
      end
    end

    def missing_manifest?(reference, errors)
      # Buildx expands Docker Hub names in its missing-manifest error. Match that
      # whole response, not a credential helper's unrelated "file not found".
      repository = reference.sub(/:[^\/:]+\z/, "")
      first_component = repository.split("/").first
      canonical = if first_component.include?(".") || first_component.include?(":") || first_component == "localhost"
        reference
      elsif repository.include?("/")
        "docker.io/#{reference}"
      else
        "docker.io/library/#{reference}"
      end
      names = [reference, canonical].uniq.map { |name| Regexp.escape(name) }.join("|")
      errors.strip.match?(/\A(?:ERROR: )?(?:#{names}): (?:not found|manifest unknown|MANIFEST_UNKNOWN)(?::[^\n]*)?\z/)
    end

    def inspect_image(reference, field)
      output, errors, status = inspect_command(reference, field)
      unless status.success?
        abort "Could not inspect #{reference}: #{errors.strip}"
      end
      JSON.parse(output).to_h
    end

    def inspect_command(reference, field)
      Open3.capture3("docker", "buildx", "imagetools", "inspect", reference, "--format", "{{json .#{field}}}")
    end

    def native_entries(manifest)
      if manifest.key?("manifests")
        manifest.fetch("manifests").reject do |entry|
          entry.dig("annotations", "vnd.docker.reference.type") == "attestation-manifest"
        end
      end
    end

    def assert_platforms(entries, expected, reference)
      platforms = entries.map do |entry|
        platform = entry.fetch("platform")
        "#{platform.fetch("os")}/#{platform.fetch("architecture")}"
      end
      unless platforms.sort == expected.sort
        abort "#{reference}: expected exactly #{expected.join(", ")}; got #{platforms.join(", ")}"
      end
    end

    def verify_config(reference, digest, architecture, version, revision, source)
      repository = reference.sub(/:[^\/:]+\z/, "")
      config = inspect_image("#{repository}@#{digest}", "Image")
      unless config.fetch("os") == "linux" && config.fetch("architecture") == architecture
        abort "#{reference}: image config does not match linux/#{architecture}"
      end
      labels = config.fetch("config").fetch("Labels")
      expected = {
        "org.opencontainers.image.version" => version,
        "org.opencontainers.image.revision" => revision,
        "org.opencontainers.image.source" => source,
      }
      expected.each do |name, value|
        unless labels[name] == value
          abort "#{reference}: linux/#{architecture} #{name} differs from the release"
        end
      end
    end
  end
end

ReleaseImages.run(ARGV)
