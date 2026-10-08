#!/usr/bin/env ruby
# A registry/Engine double for publish_test.sh; every call stays on this machine.
require "digest"
require "fileutils"
require "json"

root = ENV.fetch("MOCK_DOCKER_ROOT")
FileUtils.mkdir_p(root)
File.open(File.join(root, "calls.jsonl"), "a") { |file| file.puts(JSON.generate(ARGV)) }
arguments = ARGV.dup
context = if arguments.first == "--context"
  arguments.shift
  arguments.shift
else
  "default"
end
state_path = File.join(root, "state.json")
state = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : { "images" => {}, "registry" => {}, "contexts" => {}, "containers" => {} }
fail_at = ENV["MOCK_FAIL_AT"]
architecture = context.include?("arm64") ? "arm64" : "amd64"
save = -> { File.write(state_path, JSON.generate(state)) }
failure = ->(stage) { exit 19 if fail_at == stage }
image_digest = ->(value) { "sha256:#{Digest::SHA256.hexdigest(value)}" }
option = ->(name) { arguments.fetch(arguments.index(name) + 1) }

case arguments.first
when "context"
  case arguments[1]
  when "create"
    name = arguments.fetch(2)
    state.fetch("contexts")[name] = arguments.fetch(4)
    save.call
    puts name
  when "rm"
    state.fetch("contexts").delete(arguments.fetch(2))
    save.call
  else
    abort "unsupported fake context command: #{arguments.inspect}"
  end
when "info"
  if ENV["MOCK_NON_NATIVE"] == architecture
    puts "linux/s390x"
  else
    puts(architecture == "amd64" ? "linux/x86_64" : "linux/aarch64")
  end
when "buildx"
  case arguments[1]
  when "inspect"
    puts "Driver: #{ENV.fetch("MOCK_DRIVER", "docker")}"
  when "build"
    reference = option.call("-t")
    product = reference.split("/").last.split(":").first.delete_prefix("cybros-")
    failure.call("build-#{product}-#{architecture}")
    build_context = arguments.last
    abort "source was not archived" if File.exist?(File.join(build_context, ".git"))
    abort "ignored source reached the build" if File.exist?(File.join(build_context, "ignored-local.txt"))
    labels = {}
    arguments.each_with_index do |value, index|
      if value == "--label"
        key, label = arguments.fetch(index + 1).split("=", 2)
        labels[key] = label
      end
    end
    state.fetch("images")[reference] = {
      "digest" => image_digest.call(reference),
      "config" => { "os" => "linux", "architecture" => architecture, "config" => { "Labels" => labels } },
    }
    save.call
  when "imagetools"
    case arguments[2]
    when "inspect"
      reference = arguments.fetch(3)
      failure.call("inspect")
      artifact = state.fetch("registry")[reference]
      if !artifact && reference.include?("@")
        digest = reference.split("@", 2).last
        artifact = state.fetch("registry").values.find { |row| row.fetch("digest") == digest }
      end
      unless artifact
        if ENV["MOCK_EXISTING_TAG"] && reference.end_with?(ENV.fetch("MOCK_EXISTING_TAG"))
          puts JSON.generate({ "digest" => image_digest.call(reference) })
          exit 0
        end
        warn ENV.fetch("MOCK_REGISTRY_ERROR", "ERROR: #{reference}: not found")
        exit 1
      end
      if option.call("--format") == "{{json .Image}}"
        config = Marshal.load(Marshal.dump(artifact.fetch("config")))
        if ENV["MOCK_BAD_LABEL"] == config.fetch("architecture")
          config.fetch("config").fetch("Labels")["org.opencontainers.image.revision"] = "wrong-revision"
        end
        if ENV["MOCK_BAD_CONFIG_ARCH"] == config.fetch("architecture")
          config["architecture"] = "s390x"
        end
        puts JSON.generate(config)
      else
        manifest = Marshal.load(Marshal.dump(artifact.fetch("manifest")))
        if ENV["MOCK_BAD_RELEASE"] && reference.end_with?(":#{ENV.fetch("MOCK_RELEASE_TAG")}")
          manifest.fetch("manifests").pop
        end
        if ENV["MOCK_WRONG_RELEASE_CHILD"] && reference.end_with?(":#{ENV.fetch("MOCK_RELEASE_TAG")}")
          manifest.fetch("manifests").first["digest"] = image_digest.call("wrong-child")
        end
        if ENV["MOCK_BAD_LATEST"] && reference.end_with?(":latest")
          manifest["digest"] = image_digest.call("wrong-latest")
        end
        puts JSON.generate(manifest)
      end
    when "create"
      reference = option.call("--tag")
      sources = arguments.drop(arguments.index("--tag") + 2)
      failure.call(reference.end_with?(":latest") ? "promote-#{reference.split("/").last.split(":").first}" : "index")
      artifacts = sources.map do |source|
        digest = source.split("@", 2).last
        state.fetch("registry").values.find { |row| row.fetch("digest") == digest } || abort("missing digest #{source}")
      end
      if artifacts.length == 1
        state.fetch("registry")[reference] = artifacts.first
      else
        digest = image_digest.call(sources.join("\n"))
        entries = artifacts.map do |artifact|
          { "digest" => artifact.fetch("digest"), "platform" => { "os" => "linux", "architecture" => artifact.fetch("config").fetch("architecture") } }
        end
        state.fetch("registry")[reference] = { "digest" => digest, "manifest" => { "digest" => digest, "manifests" => entries } }
      end
      save.call
    else
      abort "unsupported fake imagetools command: #{arguments.inspect}"
    end
  else
    abort "unsupported fake buildx command: #{arguments.inspect}"
  end
when "run"
  failure.call("run-#{architecture}")
  puts "runtime smoke passed"
when "create"
  container = "smoke-#{architecture}"
  state.fetch("containers")[container] = true
  save.call
  puts container
when "cp"
  abort "runtime payload is missing" unless File.exist?(File.join(arguments.fetch(1), "runtime_smoke.sh"))
when "start"
  failure.call("smoke-#{architecture}")
  Process.kill("TERM", Process.ppid) if fail_at == "interrupt-smoke"
when "inspect"
  puts(ENV["MOCK_SMOKE_EXIT"] || "0")
when "rm"
  state.fetch("containers").delete(arguments.last)
  save.call
when "push"
  reference = arguments.fetch(1)
  failure.call("push-#{architecture}")
  artifact = state.fetch("images").fetch(reference)
  native = artifact.merge("manifest" => { "digest" => artifact.fetch("digest") })
  if ENV["MOCK_NATIVE_INDEX"]
    repository = reference.sub(/:[^\/:]+\z/, "")
    state.fetch("registry")["#{repository}@#{artifact.fetch("digest")}"] = native
    digest = image_digest.call("#{reference}-index")
    entries = [
      { "digest" => artifact.fetch("digest"), "platform" => { "os" => "linux", "architecture" => architecture } },
      { "digest" => image_digest.call("#{reference}-attestation"), "platform" => { "os" => "unknown", "architecture" => "unknown" }, "annotations" => { "vnd.docker.reference.type" => "attestation-manifest" } },
    ]
    state.fetch("registry")[reference] = { "digest" => digest, "manifest" => { "digest" => digest, "manifests" => entries } }
  else
    state.fetch("registry")[reference] = native
  end
  save.call
else
  abort "unsupported fake docker command: #{arguments.inspect}"
end
