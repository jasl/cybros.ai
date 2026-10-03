require "test_helper"

# Guards the hand-maintained Stimulus manifest: running the Rails manifest
# generator would re-register the ui/ controllers under "ui--*" identifiers
# and silently disconnect every data-controller reference in the views.
class StimulusManifestTest < ActiveSupport::TestCase
  MANIFEST = Rails.root.join("app/javascript/controllers/index.js").read
  CODE_LINES = MANIFEST.lines.reject { |line| line.strip.start_with?("//") }.join

  %w[clipboard countdown dropdown sidebar theme].each do |identifier|
    test "registers #{identifier} under its short stable identifier" do
      assert_includes CODE_LINES, "application.register(\"#{identifier}\",",
        "ui/#{identifier}_controller.js must stay registered as \"#{identifier}\""
    end
  end

  test "no namespaced ui-- identifiers leak into the registrations" do
    assert_no_match(/register\("ui--/, CODE_LINES)
  end
end
