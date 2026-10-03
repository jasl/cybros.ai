ENV["RAILS_ENV"] ||= "test"

require_relative "./simplecov_helper"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/access_token_test_helper"
require_relative "test_helpers/agent_membership_test_helper"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/dev_model_lane"
require_relative "test_helpers/invocation_harness"
require_relative "test_helpers/loop_seam_test_helper"
require_relative "test_helpers/loop_door_test_helper"
require_relative "test_helpers/loop_authoring_test_helper"
require_relative "test_helpers/loop_lane_test_helper"
require_relative "test_helpers/media_fixtures"
require_relative "test_helpers/limits_of"
require_relative "test_helpers/memory_test_helper"
require_relative "support/nexus_contract"

# Re-boot the catalog with the test-owned override directory. This is the
# ordinary override seam — the same compile path production runs with config.d
# — so the dev/mock fixture is mounted exactly like any operator-provided
# catalog fragment, and tests never read deployment-local config.d.
ModelCatalog.boot(override_dir: Rails.root.join("test/support/model_catalog"))

# The recurring schedule, read the way SOLID QUEUE reads it. Its own loader
# goes through `ActiveSupport::ConfigurationFile.parse`, i.e. `unsafe_load_file`,
# which enables YAML aliases; a bare `YAML.load_file` does not, and the file
# uses an anchor so development inherits production's schedule verbatim (parity
# is the point — without it Solid Queue registers zero recurring tasks there).
module RecurringScheduleTestHelper
  def recurring_schedule(env = "production")
    YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch(env)
  end
end

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    include RecurringScheduleTestHelper
    include MemoryTestHelper

    fixtures :all
    include AccessTokenTestHelper
    include AgentMembershipTestHelper
    include SessionFixtureTestHelper
    include LoopSeamTestHelper
    include LoopDoorTestHelper
    include LoopAuthoringTestHelper

    # Rate-limit counters (and any other cache state) never leak across tests.
    setup { Rails.cache.clear }
  end
end
