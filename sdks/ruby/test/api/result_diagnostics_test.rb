require "test_helper"
require "pp"

class ApiResultDiagnosticsTest < Minitest::Test
  def test_summary_values_redact_secret_shaped_fields_from_every_diagnostic
    summaries = [
      [
        CybrosAgent::Api::WorkspaceOwnerSummary.new(
          public_id: "owner-1",
          display_name: "sk-cybros-api-v1-owner.secret"
        ),
        "CybrosAgent::Api::WorkspaceOwnerSummary",
        "display_name=",
        "owner.secret",
      ],
      [
        CybrosAgent::Api::WorkspaceCreatorSummary.new(
          public_id: "creator-1",
          display_name: "rt-creator.secret",
          kind: "agent"
        ),
        "CybrosAgent::Api::WorkspaceCreatorSummary",
        "display_name=",
        "creator.secret",
      ],
      [
        CybrosAgent::Api::WorkspaceSummary.new(
          public_id: "workspace-1",
          name: "dc-workspace.secret",
          access_mode: "private",
          state: "active",
          dedicated: false,
          lock_version: 1,
          archived_at: nil,
          created_at: "2026-07-30T00:00:00Z",
          updated_at: "2026-07-30T01:00:00Z"
        ),
        "CybrosAgent::Api::WorkspaceSummary",
        "name=",
        "workspace.secret",
      ],
      [
        CybrosAgent::Api::StoreEntrySummary.new(
          public_id: "entry-1",
          namespace: "notes",
          key: "rc-entry.secret",
          lock_version: 2,
          created_at: "2026-07-30T00:00:00Z",
          updated_at: "2026-07-30T01:00:00Z"
        ),
        "CybrosAgent::Api::StoreEntrySummary",
        "key=",
        "entry.secret",
      ],
    ]

    summaries.each do |summary, class_name, field_label, secret|
      [summary.inspect, summary.to_s, PP.pp(summary, +"")].each do |diagnostic|
        assert_includes diagnostic, class_name
        assert_includes diagnostic, field_label
        assert_includes diagnostic, "[REDACTED]"
        refute_includes diagnostic, secret
      end
    end
  end
end
