require "test_helper"

# Every skip_before_action carries an explicit only: allowlist: a blanket skip silently exempts
# actions added to the controller later from the security or lifecycle guard it relaxes.
class SkipBeforeActionAllowlistTest < ActiveSupport::TestCase
  CONTROLLER_FILES = Dir[Rails.root.join("app/controllers/**/*.rb")]

  test "every skip_before_action declares an only: allowlist" do
    offenders = CONTROLLER_FILES.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        if line.include?("skip_before_action") && !line.include?("only:")
          "#{Pathname(file).relative_path_from(Rails.root)}:#{index + 1}"
        end
      end
    end

    assert_empty offenders,
      "skip_before_action without an only: allowlist at:\n#{offenders.join("\n")}\n" \
      "Name the exempt actions explicitly so future actions stay guarded."
  end
end
