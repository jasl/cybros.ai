namespace :uploads do
  desc "Check the default upload preview dependencies in this Nexus environment"
  task check_preview_dependencies: :environment do
    require "active_storage/vips"

    # The configured Rails previewers own native-tool discovery. These probes
    # supply only the media type; no upload, database row or preview is created.
    probe = Data.define(:content_type) do
      def video? = content_type.start_with?("video/")
    end
    checks = { "libvips" => ActiveStorage::VIPS_AVAILABLE }
    { "PDF previewer" => "application/pdf", "Video previewer" => "video/mp4" }.each do |label, content_type|
      checks[label] = ActiveStorage.previewers.any? { |previewer| previewer.accept?(probe.new(content_type)) }
    end

    puts "Active Storage variant processor: #{ActiveStorage.variant_processor}"
    checks.each { |label, available| puts "#{label}: #{available ? "available" : "missing"}" }
    puts "Dependency checks only; individual files and codecs may still fail to render."
    abort "Missing preview dependencies; see nexus/README.md, File previews." unless checks.values.all?
  end
end
