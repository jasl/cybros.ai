require "test_helper"

# `with_advisory_lock` is the last rung of the lock ladder: a short cross-row critical section no
# constraint can express, and every sanctioned site is pinned by a guard. This is that pin. A new
# site fails here until it is named below, so joining the rung is a deliberate act reviewed against
# the ladder, never a habit.
class AdvisoryLockSitesTest < ActiveSupport::TestCase
  # Each entry is `path:line`, relative to the app root.
  ADVISORY_LOCK_SITES = %w[
    app/services/model_invocations/admit_queued_work.rb:109
  ].freeze

  APP_FILES = Dir[Rails.root.join("app/**/*.rb")]

  test "every with_advisory_lock site under app/ is on the allowlist" do
    sites = APP_FILES.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        if line.include?("with_advisory_lock")
          "#{Pathname(file).relative_path_from(Rails.root)}:#{index + 1}"
        end
      end
    end

    assert_equal ADVISORY_LOCK_SITES.sort, sites.sort,
      "with_advisory_lock sites differ from ADVISORY_LOCK_SITES.\n" \
      "Found:\n#{sites.join("\n")}\n" \
      "Name each site here only for a short cross-row critical section that constraints, guarded writes, optimistic locking or an owning row lock cannot protect."
  end
end
