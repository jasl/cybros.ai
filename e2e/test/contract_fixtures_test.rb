require "test_helper"
require "support/contract_fixtures"

class ContractFixturesTest < Minitest::Test
  def test_the_complete_pack_has_a_valid_manifest_and_supported_version
    assert E2E::ContractFixtures.validate!
    assert_equal "nexus/v1", E2E::ContractFixtures.meta.fetch("contract")

    assert_raises(ArgumentError) do
      E2E::ContractFixtures.validate_version!(
        meta_contract: E2E::ContractFixtures.meta.fetch("unknown_version_fixture"),
        manifest_contract: "nexus/v1"
      )
    end
  end

  def test_every_exported_contract_has_valid_and_unknown_behavior_fixtures
    coverage = E2E::ContractFixtures.coverage

    %w[protocol_versions closed_discriminators terminal_classes stable_error_families].each do |section|
      entries = coverage.fetch(section)
      refute_empty entries

      entries.each do |name, entry|
        refute_empty entry.fetch("consumers"), name
        refute_empty entry.fetch("unknown_behavior"), name
        refute_nil E2E::ContractFixtures.resolve(entry.fetch("valid_fixture")), name
        refute_nil E2E::ContractFixtures.resolve(entry.fetch("unknown_fixture")), name
      end
    end
  end

  # THE UPLOAD PACK: one descriptor for the three ingest doors, one bytes read with its statuses,
  # and the result grammar's closed block kinds beside it — what the capture journey and the SDK
  # read by name.
  def test_the_upload_pack_names_the_doors_the_bytes_read_and_the_link_kind
    uploads = E2E::ContractFixtures.uploads
    assert_equal %w[executor member session], uploads.fetch("ingest_paths").keys.sort
    assert_equal "/agent_api/v1/uploads/{public_id}/bytes", uploads.fetch("bytes_path")
    assert_equal({ "whole" => 200, "range" => 206, "fresh" => 304, "absent" => 404 }, uploads.fetch("bytes_statuses"))
    # THE TWO NAMED REPRESENTATION READS: their paths, their bounds, the 304 every attachment read
    # answers, the typed refusal's code.
    assert_equal({ "thumbnail" => "/agent_api/v1/uploads/{public_id}/thumbnail",
                   "preview" => "/agent_api/v1/uploads/{public_id}/preview" }, uploads.fetch("representation_paths"))
    assert_equal({ "thumbnail" => 256, "preview" => 1600 }, uploads.fetch("representation_bounds"))
    assert_equal({ "whole" => 200, "fresh" => 304, "unavailable" => 404 }, uploads.fetch("representation_statuses"))
    assert_equal 404, uploads.dig("error_statuses", "representation_unavailable")
    assert_equal "max-age=31556952, private", uploads.fetch("attachment_cache_control"), "Rails' directive order"
    assert_equal %w[byte_size content_type created_at filename public_id],
      uploads.dig("valid_fixture", "upload").keys.sort
    assert_equal uploads.fetch("descriptor_projection").sort, uploads.dig("valid_fixture", "upload").keys.sort

    inbox = E2E::ContractFixtures.executor_inbox
    assert_equal %w[text resource_link], inbox.fetch("content_kinds")
    assert_equal 422, inbox.dig("error_statuses", "unknown_result_upload")
    link = inbox.dig("commit_link_fixture", "content", 1)
    assert_equal "resource_link", link.fetch("type")
    assert link.fetch("uri").start_with?(inbox.fetch("resource_link_uri_prefix"))
    assert_equal E2E::ContractFixtures.meta.fetch("unknown_value_fixture"),
      inbox.dig("unknown_content_kind_fixture", "content", 1, "type")
  end

  # THE MODEL PLANE'S PACK (audit wire-22): the listing and lane envelopes,
  # the three closed words a console reads, the 503 a never-compiled
  # catalog answers — every fixture the coverage rows point at resolves.
  def test_the_models_pack_names_the_listing_the_lanes_and_the_three_vocabularies
    models = E2E::ContractFixtures.models
    assert_equal ["models"], models.fetch("listing_envelope")
    assert_equal ["model_providers"], models.fetch("providers_envelope")
    assert_equal %w[cost_unknown known_free_candidate priced unmetered], models.fetch("pricing_states").sort
    assert_equal %w[api_key none oauth_tokens], models.fetch("credentials")
    assert_includes models.fetch("unavailable_reasons"), "provider_disabled"
    assert_equal 503, models.dig("error_statuses", "model_plane_unavailable")
    row = models.dig("valid_fixture", "models", 0)
    assert_equal models.fetch("row_projection"), row.keys
    assert row.fetch("available")
    assert_nil row.fetch("unavailable_reason")
    refute models.dig("unavailable_fixture", "available")
    assert_includes models.fetch("unavailable_reasons"), models.dig("unavailable_fixture", "unavailable_reason")
    assert_equal models.fetch("provider_projection"), models.dig("valid_provider_fixture", "model_provider").keys
  end

  # THE TWO PLANES' TABLES (audit wire-17) and the extend door (wire-15):
  # the words the journeys branch on are pinned with their statuses, and
  # the executor plane's extension has its envelope, its fixture and its
  # three codes.
  def test_the_two_planes_publish_their_error_tables_and_the_inbox_its_extend_door
    conversations = E2E::ContractFixtures.conversations
    assert_equal 409, conversations.dig("error_statuses", "conversation_busy")
    assert_equal 403, conversations.dig("error_statuses", "not_authorized")
    assert_equal 404, conversations.dig("error_statuses", "runner_not_found")
    assert_equal 422, conversations.fetch("refusal_default_status")
    assert_equal %w[after limit order order_by side], conversations.fetch("list_filters").sort
    assert_equal %w[asc desc], conversations.fetch("list_directions")
    assert_equal %w[public_id last_activity_at], conversations.fetch("list_order_by")

    loops = E2E::ContractFixtures.runs
    assert_equal 409, loops.dig("error_statuses", "stale_revision")
    assert_equal 422, loops.dig("error_statuses", "invalid_steps")
    assert_equal 409, loops.dig("error_statuses", "conversation_hosted")
    assert_equal %w[after attention limit order status], loops.fetch("list_filters").sort
    assert_equal loops.fetch("task_progress_projection").sort,
      loops.dig("valid_request_run_fixture", "run", "task_progress").keys.sort

    inbox = E2E::ContractFixtures.executor_inbox
    assert_equal %w[claim_token timeout_ms], inbox.fetch("extend_envelope")
    assert_equal %w[claim task], inbox.fetch("extend_fixture").keys.sort
    assert_equal inbox.dig("extend_request_fixture", "claim_token"), inbox.dig("extend_fixture", "claim", "claim_token"),
      "the token is unrotated"
    %w[not_extendable extension_too_long not_claimant].each { |code| assert_equal 409, inbox.dig("error_statuses", code) }
    assert_equal 422, inbox.dig("error_statuses", "invalid_timeout_ms")
    assert_equal 409, inbox.dig("error_statuses", "task_not_running")

    executors = E2E::ContractFixtures.task_executors
    assert_equal ["executors"], executors.fetch("discovery_envelope")
    assert_equal %w[runner tool_provider], executors.fetch("discovery_kinds")
    assert_equal ["kind"], executors.fetch("discovery_filters")

    errors = E2E::ContractFixtures.errors
    assert_equal %w[conversation_hosted edge_authoring_refused invalid_steps stale_revision],
      errors.fetch("extended_envelopes").keys.sort
    assert_equal ["current_revision"], errors.dig("extended_envelopes", "stale_revision")
    assert_equal 4, errors.dig("extended_fixture", "body", "error", "current_revision")
  end

  def test_platform_admin_removal_is_not_an_sdk_contract
    admin_entries = E2E::ContractFixtures.coverage.fetch("stable_error_families")
      .fetch("platform.admin_user_removal")

    assert_equal %w[e2e nexus], admin_entries.fetch("consumers").sort
    refute_includes admin_entries.fetch("consumers"), "sdk"
  end

  def test_platform_profile_plane_stays_raw_and_outside_the_sdk
    entry = E2E::ContractFixtures.coverage.fetch("closed_discriminators")
      .fetch("platform_profile.credential_plane")
    profiles = E2E::ContractFixtures.profiles

    assert_equal %w[e2e nexus], entry.fetch("consumers").sort
    refute_includes entry.fetch("consumers"), "sdk"
    assert_equal "platform", profiles.dig("platform_api_token", "credential_plane")
    assert_equal profiles.fetch("unknown_value_fixture"),
      profiles.dig("unknown_platform_credential_plane_fixture", "credential_plane")
  end

  def test_workspace_creator_kind_is_a_shared_additive_contract
    entry = E2E::ContractFixtures.coverage.fetch("closed_discriminators")
      .fetch("workspace.creator.kind")
    workspaces = E2E::ContractFixtures.workspaces

    assert_equal %w[e2e nexus sdk], entry.fetch("consumers").sort
    assert_equal "carry_unknown", entry.fetch("unknown_behavior")
    assert_equal workspaces.dig("valid_full_fixture", "workspace", "creator", "kind"),
      E2E::ContractFixtures.resolve(entry.fetch("valid_fixture"))
    assert_equal E2E::ContractFixtures.meta.fetch("unknown_value_fixture"),
      workspaces.dig("unknown_creator_kind_fixture", "creator", "kind")
  end

  def test_admin_identity_fields_and_session_token_type_stay_outside_the_sdk
    entries = E2E::ContractFixtures.coverage.fetch("closed_discriminators")
    admin_users = E2E::ContractFixtures.admin_users
    sessions = E2E::ContractFixtures.sessions

    {
      "admin_user.kind" => "unknown_kind_fixture",
      "admin_user.role" => "unknown_role_fixture",
    }.each do |name, fixture_name|
      entry = entries.fetch(name)
      field = name.delete_prefix("admin_user.")

      assert_equal %w[e2e nexus], entry.fetch("consumers").sort
      refute_includes entry.fetch("consumers"), "sdk"
      assert_equal "carry_unknown", entry.fetch("unknown_behavior")
      assert_equal admin_users.fetch("unknown_value_fixture"),
        admin_users.dig(fixture_name, "user", field)
    end

    token_type = entries.fetch("platform.session.token_type")
    assert_equal %w[e2e nexus], token_type.fetch("consumers").sort
    refute_includes token_type.fetch("consumers"), "sdk"
    assert_equal "reject_response", token_type.fetch("unknown_behavior")
    assert_equal sessions.fetch("unknown_value_fixture"),
      sessions.fetch("unknown_token_type_fixture").fetch("token_type")
  end

  def test_consumed_cancellation_is_a_terminal_shared_fixture
    entry = E2E::ContractFixtures.coverage.fetch("terminal_classes")
      .fetch("oauth.cancellation_consumed")
    fixture = E2E::ContractFixtures.oauth.fetch("consumed_cancellation_fixture")

    assert_equal %w[e2e nexus sdk], entry.fetch("consumers").sort
    assert_equal 409, fixture.fetch("status")
    assert_equal "too_late", fixture.dig("body", "error")
  end
end
