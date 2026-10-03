# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_10_02_013000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "access_tokens", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "name", limit: 160, null: false
    t.string "note", limit: 2000
    t.string "source", limit: 20, default: "personal", null: false
    t.string "credential_plane", limit: 20, default: "member", null: false
    t.string "lookup_id", limit: 24, null: false
    t.string "secret_digest", null: false
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.datetime "last_used_at"
    t.bigint "task_executor_id"
    t.integer "credential_epoch"
    t.integer "user_authority_generation"
    t.integer "identity_recovery_generation"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "refresh_token_family_id"
    t.index ["account_id"], name: "index_access_tokens_on_account_id"
    t.index ["expires_at", "id"], name: "index_access_tokens_on_expires_at_and_id"
    t.index ["lookup_id"], name: "index_access_tokens_on_lookup_id", unique: true
    t.index ["public_id"], name: "index_access_tokens_on_public_id", unique: true
    t.index ["refresh_token_family_id"], name: "index_access_tokens_on_refresh_token_family_id"
    t.index ["revoked_at", "id"], name: "index_access_tokens_on_revoked_at_and_id"
    t.index ["task_executor_id"], name: "index_access_tokens_on_task_executor_id"
    t.index ["user_id"], name: "index_access_tokens_on_user_id"
  end

  create_table "accounts", force: :cascade do |t|
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "name", limit: 100, null: false
    t.string "cost_unit", limit: 64
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "execution_details_retention_days", default: 90
    t.index "(true)", name: "index_accounts_singleton", unique: true
    t.index ["public_id"], name: "index_accounts_on_public_id", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "actors", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "kind", limit: 16, null: false
    t.bigint "user_id"
    t.string "channel_key", limit: 64, null: false
    t.string "external_id", limit: 128, null: false
    t.string "display_name", limit: 100, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "channel_key", "external_id"], name: "index_actors_on_natural_key", unique: true
    t.index ["public_id"], name: "index_actors_on_public_id", unique: true
    t.index ["user_id"], name: "index_actors_on_user_id"
  end

  create_table "agent_loop_append_receipts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "agent_loop_id", null: false
    t.string "idempotency_key", limit: 36, null: false
    t.string "request_digest", limit: 64, null: false
    t.integer "response_status", null: false
    t.jsonb "response_body", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_agent_loop_append_receipts_on_account_id"
    t.index ["agent_loop_id", "idempotency_key"], name: "idx_on_agent_loop_id_idempotency_key_d472f9e2a9", unique: true
    t.index ["agent_loop_id"], name: "index_agent_loop_append_receipts_on_agent_loop_id"
    t.index ["created_at", "id"], name: "index_agent_loop_append_receipts_on_created_at_and_id"
  end

  create_table "agent_loop_create_receipts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.bigint "creating_user_id", null: false
    t.bigint "agent_loop_id", null: false
    t.string "idempotency_key", limit: 36, null: false
    t.string "request_digest", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_agent_loop_create_receipts_on_account_id"
    t.index ["agent_loop_id"], name: "index_agent_loop_create_receipts_on_agent_loop_id"
    t.index ["created_at", "id"], name: "index_agent_loop_create_receipts_on_created_at_and_id"
    t.index ["creating_user_id"], name: "index_agent_loop_create_receipts_on_creating_user_id"
    t.index ["workspace_id", "creating_user_id", "idempotency_key"], name: "idx_agent_loop_create_receipts_replay_scope", unique: true
    t.index ["workspace_id"], name: "index_agent_loop_create_receipts_on_workspace_id"
  end

  create_table "agent_loop_edges", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "agent_loop_id", null: false
    t.bigint "from_node_id", null: false
    t.bigint "to_node_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "structural", default: true, null: false
    t.index ["account_id"], name: "index_agent_loop_edges_on_account_id"
    t.index ["agent_loop_id", "from_node_id"], name: "index_agent_loop_edges_on_agent_loop_id_and_from_node_id"
    t.index ["agent_loop_id", "to_node_id"], name: "index_agent_loop_edges_on_agent_loop_id_and_to_node_id"
    t.index ["agent_loop_id"], name: "index_agent_loop_edges_on_agent_loop_id"
    t.index ["from_node_id", "to_node_id"], name: "index_agent_loop_edges_on_from_node_id_and_to_node_id", unique: true
  end

  create_table "agent_loop_nodes", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "agent_loop_id", null: false
    t.string "node_key", limit: 64, null: false, collation: "C"
    t.string "type", null: false
    t.string "status", default: "queued", null: false
    t.integer "remaining_dependencies", default: 0, null: false
    t.integer "execution_generation", default: 0, null: false
    t.integer "retry_budget", default: 0, null: false
    t.string "on_failure", limit: 16, default: "propagate", null: false
    t.string "failure_resolution", limit: 16
    t.string "transcript_visibility", limit: 16, default: "visible", null: false
    t.jsonb "output_summary", default: {}, null: false
    t.string "provider_id", limit: 64
    t.string "model_ref", limit: 128
    t.string "reasoning_effort", limit: 32
    t.jsonb "request_options", default: {}, null: false
    t.string "input_from_node_keys", array: true
    t.string "tool_name", limit: 128
    t.jsonb "tool_input", default: {}, null: false
    t.integer "timeout_ms"
    t.integer "await_timeout_ms"
    t.jsonb "ask_options"
    t.boolean "ask_multi"
    t.uuid "resolution_token"
    t.datetime "await_started_at"
    t.string "join_mode", limit: 8
    t.integer "quorum_k"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "error_key", limit: 64
    t.string "error_detail", limit: 256
    t.bigint "selected_model_invocation_id"
    t.string "loser_policy", limit: 16
    t.integer "auto_retries_used", default: 0, null: false
    t.jsonb "tool_definitions"
    t.string "continuation_source", limit: 32
    t.string "tool_call_id", limit: 128
    t.text "system_instructions"
    t.string "fan_on_failure", limit: 16
    t.string "claim_token", limit: 64
    t.datetime "claimed_at"
    t.bigint "claimed_by_executor_id"
    t.uuid "claimed_by_executor_public_id"
    t.string "output_preview", limit: 280
    t.integer "output_size_bytes"
    t.string "result_title", limit: 200
    t.jsonb "result_metadata"
    t.boolean "detached", default: false, null: false
    t.jsonb "compaction"
    t.datetime "mailed_at"
    t.bigint "addressed_executor_id"
    t.string "addressed_role"
    t.jsonb "effect_profile"
    t.string "authored_by", null: false
    t.string "approval_origin"
    t.bigint "approved_by_user_id"
    t.datetime "approval_decided_at"
    t.string "tool_alias", limit: 128
    t.string "lifetime", default: "conversation", null: false
    t.uuid "delegated_input_public_id"
    t.string "wake", default: "auto", null: false
    t.uuid "awaited_agent_loop_public_id"
    t.string "awaited_task_key", limit: 128, collation: "C"
    t.string "lifecycle_event"
    t.string "result_from_node_keys", array: true
    t.bigint "expansion_parent_id"
    t.bigint "barrier_node_id"
    t.index ["account_id"], name: "index_agent_loop_nodes_on_account_id"
    t.index ["addressed_executor_id", "id"], name: "index_agent_loop_nodes_on_addressed_frontier", where: "((status)::text = ANY (ARRAY['dispatched'::text, 'awaiting_input'::text, 'needs_approval'::text]))"
    t.index ["addressed_role", "id"], name: "index_agent_loop_nodes_on_pool_frontier", where: "((addressed_executor_id IS NULL) AND ((status)::text = 'dispatched'::text))"
    t.index ["agent_loop_id", "lifecycle_event"], name: "index_agent_loop_nodes_on_lifecycle_event", where: "(lifecycle_event IS NOT NULL)"
    t.index ["agent_loop_id", "node_key"], name: "index_agent_loop_nodes_on_agent_loop_id_and_node_key", unique: true
    t.index ["agent_loop_id", "status"], name: "index_agent_loop_nodes_on_agent_loop_id_and_status"
    t.index ["agent_loop_id", "status"], name: "index_agent_loop_nodes_on_detached_frontier", where: "detached"
    t.index ["agent_loop_id", "tool_call_id"], name: "index_agent_loop_nodes_on_tool_call_id", where: "(tool_call_id IS NOT NULL)"
    t.index ["agent_loop_id"], name: "index_agent_loop_nodes_on_agent_loop_id"
    t.index ["approved_by_user_id"], name: "index_agent_loop_nodes_on_approved_by_user_id"
    t.index ["awaited_agent_loop_public_id"], name: "index_agent_loop_nodes_on_wait_target", where: "((awaited_task_key IS NOT NULL) AND ((status)::text = 'dispatched'::text))"
    t.index ["barrier_node_id"], name: "index_agent_loop_nodes_on_barrier_node_id"
    t.index ["claimed_by_executor_id"], name: "index_agent_loop_nodes_on_claimant", where: "((status)::text = 'dispatched'::text)"
    t.index ["expansion_parent_id"], name: "index_agent_loop_nodes_on_expansion_parent_id"
    t.index ["id"], name: "index_agent_loop_nodes_mail_frontier", where: "(detached AND (mailed_at IS NULL) AND ((status)::text = ANY (ARRAY['completed'::text, 'failed'::text, 'canceled'::text, 'timed_out'::text, 'uncertain'::text, 'skipped'::text])))"
    t.index ["id"], name: "index_agent_loop_nodes_on_delegation_frontier", where: "(((type)::text = 'AgentLoopNodes::DelegationTask'::text) AND ((status)::text = ANY (ARRAY['queued'::text, 'running'::text, 'canceled'::text, 'skipped'::text])))"
    t.index ["id"], name: "index_agent_loop_nodes_on_park_frontier", where: "((await_started_at IS NOT NULL) AND ((status)::text = ANY (ARRAY['running'::text, 'dispatched'::text, 'awaiting_input'::text, 'needs_approval'::text])))"
    t.index ["resolution_token"], name: "index_agent_loop_nodes_on_resolution_token", unique: true, where: "(resolution_token IS NOT NULL)"
  end

  create_table "agent_loops", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.bigint "creating_user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "status", default: "pending", null: false
    t.string "failure_reason", limit: 64
    t.bigint "revision", default: 0, null: false
    t.bigint "deliverable_node_id"
    t.datetime "tombstoned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "paused_at"
    t.string "attention_reason", limit: 64
    t.string "billing_subject_key", limit: 128
    t.uuid "billing_subject_public_id"
    t.datetime "canceling_since"
    t.bigint "conversation_turn_variant_id"
    t.datetime "delivered_at"
    t.string "prompt_mechanism"
    t.bigint "runner_executor_id"
    t.string "approval_mode", null: false
    t.jsonb "approval_rules"
    t.boolean "mail_model_fallback_used", default: false, null: false
    t.jsonb "lifecycle_hooks"
    t.datetime "details_pruned_at"
    t.datetime "stopped_at"
    t.index ["account_id", "completed_at", "id"], name: "index_agent_loops_on_detail_retention", where: "((details_pruned_at IS NULL) AND (conversation_turn_variant_id IS NOT NULL) AND ((status)::text = ANY (ARRAY['completed'::text, 'canceled'::text])))"
    t.index ["account_id"], name: "index_agent_loops_on_account_id"
    t.index ["conversation_turn_variant_id"], name: "index_agent_loops_on_conversation_turn_variant_id", unique: true, where: "(conversation_turn_variant_id IS NOT NULL)"
    t.index ["creating_user_id"], name: "index_agent_loops_on_creating_user_id"
    t.index ["id"], name: "index_agent_loops_drain_frontier", where: "((status)::text = 'canceling'::text)"
    t.index ["id"], name: "index_agent_loops_stop_frontier", where: "((status)::text = ANY (ARRAY['pending'::text, 'running'::text, 'canceling'::text, 'paused'::text, 'needs_attention'::text]))"
    t.index ["public_id"], name: "index_agent_loops_on_public_id", unique: true
    t.index ["runner_executor_id"], name: "index_agent_loops_on_runner_executor_id"
    t.index ["status"], name: "index_agent_loops_on_live_execution", where: "((status)::text = ANY (ARRAY['running'::text, 'paused'::text, 'needs_attention'::text, 'canceling'::text]))"
    t.index ["tombstoned_at", "id"], name: "index_agent_loops_reap_frontier", where: "(tombstoned_at IS NOT NULL)"
    t.index ["workspace_id", "public_id"], name: "index_agent_loops_on_workspace_and_listable_public_id", where: "(tombstoned_at IS NULL)"
    t.index ["workspace_id", "status"], name: "index_agent_loops_on_workspace_id_and_status"
    t.index ["workspace_id"], name: "index_agent_loops_on_workspace_id"
  end

  create_table "billing_subjects", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "owning_user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "key", limit: 128, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "key"], name: "index_billing_subjects_on_account_id_and_key", unique: true
    t.index ["account_id"], name: "index_billing_subjects_on_account_id"
    t.index ["owning_user_id"], name: "index_billing_subjects_on_owning_user_id"
    t.index ["public_id"], name: "index_billing_subjects_on_public_id", unique: true
  end

  create_table "content_bodies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "role", limit: 32, null: false
    t.text "readable_text"
    t.datetime "sealed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "one_shot_id"
    t.bigint "model_invocation_id"
    t.bigint "conversation_input_id"
    t.bigint "conversation_turn_variant_id"
    t.bigint "agent_loop_node_id"
    t.integer "byte_size"
    t.text "search_terms", default: [], null: false, array: true
    t.index ["account_id"], name: "index_content_bodies_on_account_id"
    t.index ["agent_loop_node_id"], name: "index_content_bodies_on_agent_loop_node_id", where: "(agent_loop_node_id IS NOT NULL)"
    t.index ["conversation_input_id"], name: "index_content_bodies_on_conversation_input_id", where: "(conversation_input_id IS NOT NULL)"
    t.index ["conversation_turn_variant_id"], name: "index_content_bodies_on_conversation_turn_variant_id", where: "(conversation_turn_variant_id IS NOT NULL)"
    t.index ["model_invocation_id"], name: "index_content_bodies_on_model_invocation_id"
    t.index ["one_shot_id"], name: "index_content_bodies_on_one_shot_id"
    t.index ["search_terms"], name: "index_content_bodies_on_search_terms", where: "((conversation_turn_variant_id IS NOT NULL) AND (sealed_at IS NOT NULL) AND ((role)::text = ANY (ARRAY['prompt'::text, 'content'::text, 'steers'::text])))", using: :gin
  end

  create_table "content_body_entries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "content_body_id", null: false
    t.bigint "content_fragment_id", null: false
    t.integer "position", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_content_body_entries_on_account_id"
    t.index ["content_body_id", "position"], name: "index_content_body_entries_on_content_body_id_and_position", unique: true
    t.index ["content_fragment_id"], name: "index_content_body_entries_on_content_fragment_id"
  end

  create_table "content_body_uploads", id: false, force: :cascade do |t|
    t.bigint "content_body_id", null: false
    t.bigint "content_upload_id", null: false
    t.index ["content_body_id", "content_upload_id"], name: "idx_on_content_body_id_content_upload_id_741c0c3fd5", unique: true
    t.index ["content_upload_id"], name: "index_content_body_uploads_on_content_upload_id"
  end

  create_table "content_fragments", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "digest", limit: 64, null: false
    t.jsonb "payload", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "digest"], name: "index_content_fragments_on_account_id_and_digest", unique: true
    t.index ["created_at", "id"], name: "index_content_fragments_on_created_at_and_id"
  end

  create_table "content_uploads", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "creating_user_id"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "creating_executor_id"
    t.index ["account_id"], name: "index_content_uploads_on_account_id"
    t.index ["created_at", "id"], name: "index_content_uploads_on_created_at_and_id"
    t.index ["creating_executor_id"], name: "index_content_uploads_on_creating_executor_id"
    t.index ["creating_user_id"], name: "index_content_uploads_on_creating_user_id"
    t.index ["public_id"], name: "index_content_uploads_on_public_id", unique: true
  end

  create_table "conversation_access_entries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "user_id", null: false
    t.string "level", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conversation_access_entries_on_account_id"
    t.index ["conversation_id", "user_id"], name: "index_conversation_access_entries_identity", unique: true
    t.index ["user_id"], name: "index_conversation_access_entries_on_user_id"
  end

  create_table "conversation_ancestries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "ancestor_conversation_id", null: false
    t.integer "depth", null: false
    t.integer "boundary_position", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conversation_ancestries_on_account_id"
    t.index ["ancestor_conversation_id"], name: "index_conversation_ancestries_on_ancestor_conversation_id"
    t.index ["conversation_id", "ancestor_conversation_id"], name: "index_conversation_ancestries_identity", unique: true
    t.index ["conversation_id", "depth"], name: "index_conversation_ancestries_on_conversation_id_and_depth", unique: true
  end

  create_table "conversation_command_receipts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.string "host_type"
    t.bigint "host_id"
    t.bigint "acting_user_id", null: false
    t.string "operation", limit: 32, null: false
    t.string "idempotency_key", limit: 255, null: false
    t.string "request_digest", limit: 64, null: false
    t.integer "response_status", null: false
    t.jsonb "response_body", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conversation_command_receipts_on_account_id"
    t.index ["acting_user_id"], name: "index_conversation_command_receipts_on_acting_user_id"
    t.index ["created_at", "id"], name: "index_conversation_command_receipts_on_created_at_and_id"
    t.index ["host_type", "host_id", "acting_user_id", "idempotency_key"], name: "index_conversation_receipts_scheduled_job_create", unique: true, where: "((operation)::text = 'scheduled_job_create'::text)"
    t.index ["host_type", "host_id", "acting_user_id", "operation", "idempotency_key"], name: "index_conversation_receipts_on_member", unique: true, where: "(host_id IS NOT NULL)"
    t.index ["workspace_id", "acting_user_id", "idempotency_key"], name: "index_conversation_receipts_on_create", unique: true, where: "((operation)::text = 'conversation_create'::text)"
    t.index ["workspace_id", "id"], name: "index_conversation_command_receipts_on_workspace_id_and_id"
  end

  create_table "conversation_event_cursors", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "host_type", null: false
    t.bigint "host_id", null: false
    t.bigint "next_sequence", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["host_type", "host_id"], name: "index_conversation_event_cursors_on_host", unique: true
  end

  create_table "conversation_event_items", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_event_id", null: false
    t.string "host_type", null: false
    t.bigint "host_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.bigint "sequence", null: false
    t.string "item_type", limit: 40, null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_event_id"], name: "index_conversation_event_items_on_conversation_event_id"
    t.index ["created_at", "id"], name: "index_conversation_event_items_on_created_at_and_id"
    t.index ["host_type", "host_id", "sequence"], name: "index_conversation_event_items_on_sequence", unique: true
    t.index ["public_id"], name: "index_conversation_event_items_on_public_id", unique: true
  end

  create_table "conversation_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "host_type", null: false
    t.bigint "host_id", null: false
    t.string "idempotency_key", limit: 36, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["host_type", "host_id", "idempotency_key"], name: "index_conversation_events_on_key", unique: true
  end

  create_table "conversation_inputs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "host_type", null: false
    t.bigint "host_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.integer "queue_position", null: false
    t.string "kind", limit: 20, null: false
    t.string "role", limit: 10, default: "user", null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.string "delivery_mode", limit: 8, default: "queue", null: false
    t.bigint "speaker_actor_id", null: false
    t.bigint "authoring_user_id", null: false
    t.boolean "visible_in_context", default: true, null: false
    t.string "origin", limit: 64, null: false
    t.uuid "sender_conversation_public_id"
    t.bigint "steering_target_turn_id"
    t.bigint "expected_context_revision"
    t.uuid "expected_tail_turn_public_id"
    t.string "blocked_reason", limit: 64
    t.string "provider_id", limit: 64
    t.string "model_ref", limit: 128
    t.string "reasoning_effort", limit: 32
    t.jsonb "request_options", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "context_mode", limit: 16, default: "assembled", null: false
    t.jsonb "context_options", default: {}, null: false
    t.string "tool_names", array: true
    t.string "approval_mode"
    t.text "instructions"
    t.bigint "answering_user_id", null: false
    t.datetime "deliver_at"
    t.uuid "sender_agent_loop_public_id"
    t.string "sender_task_key", limit: 64
    t.uuid "expected_steering_loop_public_id"
    t.jsonb "callback_result"
    t.index ["account_id"], name: "index_conversation_inputs_on_account_id"
    t.index ["answering_user_id"], name: "index_conversation_inputs_on_answering_user_id"
    t.index ["authoring_user_id"], name: "index_conversation_inputs_on_authoring_user_id"
    t.index ["deliver_at", "id"], name: "index_conversation_inputs_due", where: "((deliver_at IS NOT NULL) AND ((state)::text = 'pending'::text) AND ((host_type)::text = 'Conversation'::text))"
    t.index ["host_type", "host_id", "queue_position"], name: "index_conversation_inputs_fifo", unique: true
    t.index ["id"], name: "index_conversation_inputs_source_frontier", where: "(sender_agent_loop_public_id IS NOT NULL)"
    t.index ["public_id"], name: "index_conversation_inputs_on_public_id", unique: true
    t.index ["sender_agent_loop_public_id", "id"], name: "index_conversation_inputs_on_source_work", where: "(sender_agent_loop_public_id IS NOT NULL)"
    t.index ["speaker_actor_id"], name: "index_conversation_inputs_on_speaker_actor_id"
    t.index ["steering_target_turn_id"], name: "index_conversation_inputs_on_steering_target_turn_id"
  end

  create_table "conversation_turn_overrides", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "conversation_turn_id", null: false
    t.string "visibility", limit: 24, null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conversation_turn_overrides_on_account_id"
    t.index ["conversation_id", "conversation_turn_id"], name: "index_conversation_turn_overrides_identity", unique: true
    t.index ["conversation_turn_id"], name: "index_conversation_turn_overrides_on_conversation_turn_id"
  end

  create_table "conversation_turn_variants", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_turn_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.integer "position", null: false
    t.string "status", limit: 16, null: false
    t.string "source", limit: 16, null: false
    t.bigint "origin_variant_id"
    t.string "provider_id", limit: 64
    t.string "model_ref", limit: 128
    t.string "reasoning_effort", limit: 32
    t.bigint "model_invocation_id"
    t.string "content_preview", limit: 140
    t.integer "content_size_bytes"
    t.datetime "deleted_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "context_mode", default: "assembled", null: false
    t.datetime "details_pruned_at"
    t.jsonb "memory_context"
    t.index ["account_id"], name: "index_conversation_turn_variants_on_account_id"
    t.index ["conversation_turn_id", "position"], name: "index_conversation_turn_variants_position", unique: true, where: "(deleted_at IS NULL)"
    t.index ["conversation_turn_id"], name: "index_conversation_turn_variants_on_conversation_turn_id"
    t.index ["conversation_turn_id"], name: "index_conversation_turn_variants_one_active", unique: true, where: "(((status)::text = ANY (ARRAY['pending'::text, 'running'::text])) AND (deleted_at IS NULL))"
    t.index ["id"], name: "index_conversation_turn_variants_settle_frontier", where: "((deleted_at IS NULL) AND ((status)::text = ANY (ARRAY['pending'::text, 'running'::text, 'failed'::text])))"
    t.index ["model_invocation_id"], name: "index_conversation_turn_variants_on_model_invocation_id", unique: true, where: "(model_invocation_id IS NOT NULL)"
    t.index ["origin_variant_id"], name: "index_conversation_turn_variants_on_origin_variant_id"
    t.index ["public_id"], name: "index_conversation_turn_variants_on_public_id", unique: true
  end

  create_table "conversation_turns", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.integer "position", null: false
    t.string "kind", limit: 20, null: false
    t.string "role", limit: 10, null: false
    t.string "status", limit: 16, null: false
    t.bigint "speaker_actor_id", null: false
    t.bigint "control_owner_user_id", null: false
    t.string "visibility", limit: 24, default: "visible", null: false
    t.bigint "active_variant_id"
    t.string "origin", limit: 64
    t.uuid "sender_conversation_public_id"
    t.uuid "forked_from_turn_public_id"
    t.uuid "forked_from_variant_public_id"
    t.datetime "deleted_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "relayed_at"
    t.bigint "answering_user_id", null: false
    t.uuid "sender_agent_loop_public_id"
    t.string "sender_task_key", limit: 64
    t.uuid "input_public_id"
    t.jsonb "callback_sources", default: [], null: false
    t.index ["account_id"], name: "index_conversation_turns_on_account_id"
    t.index ["active_variant_id"], name: "index_conversation_turns_on_active_variant_id"
    t.index ["answering_user_id"], name: "index_conversation_turns_on_answering_user_id"
    t.index ["control_owner_user_id"], name: "index_conversation_turns_on_control_owner_user_id"
    t.index ["conversation_id", "position"], name: "index_conversation_turns_nondefault_view", where: "(((visibility)::text <> 'visible'::text) OR (deleted_at IS NOT NULL))"
    t.index ["conversation_id", "position"], name: "index_conversation_turns_on_conversation_id_and_position", unique: true
    t.index ["conversation_id", "sender_agent_loop_public_id", "sender_task_key"], name: "index_conversation_turns_on_dispatch", where: "(sender_agent_loop_public_id IS NOT NULL)"
    t.index ["conversation_id"], name: "index_conversation_turns_one_active", unique: true, where: "((status)::text = ANY (ARRAY['pending'::text, 'running'::text]))"
    t.index ["public_id"], name: "index_conversation_turns_on_public_id", unique: true
    t.index ["sender_agent_loop_public_id", "id"], name: "index_conversation_turns_on_source_work", where: "(sender_agent_loop_public_id IS NOT NULL)"
    t.index ["speaker_actor_id"], name: "index_conversation_turns_on_speaker_actor_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.bigint "creating_user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "title", limit: 255
    t.jsonb "metadata", default: {}, null: false
    t.string "billing_subject_key", limit: 128
    t.uuid "billing_subject_public_id"
    t.bigint "parent_conversation_id"
    t.uuid "parent_conversation_public_id"
    t.uuid "forked_from_turn_public_id"
    t.uuid "forked_from_variant_public_id"
    t.bigint "active_turn_id"
    t.integer "timeline_position_head", default: 0, null: false
    t.bigint "context_revision", default: 0, null: false
    t.integer "input_queue_limit", default: 32, null: false
    t.datetime "last_activity_at", null: false
    t.datetime "archived_at"
    t.datetime "tombstoned_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "reasoning_replay_downgraded_at"
    t.bigint "runner_executor_id"
    t.bigint "answering_user_id", null: false
    t.boolean "side", default: false, null: false
    t.string "access_default", default: "full", null: false
    t.bigint "spawn_node_id"
    t.string "spawn_label", limit: 64
    t.text "search_terms", default: [], null: false, array: true
    t.jsonb "memory_context"
    t.bigint "scheduled_job_id"
    t.uuid "scheduled_job_public_id"
    t.datetime "scheduled_for"
    t.uuid "scheduled_input_public_id"
    t.uuid "scheduled_turn_public_id"
    t.index ["account_id"], name: "index_conversations_on_account_id"
    t.index ["active_turn_id"], name: "index_conversations_on_active_turn_id"
    t.index ["answering_user_id"], name: "index_conversations_on_answering_user_id"
    t.index ["forked_from_turn_public_id"], name: "index_conversations_on_forked_from_turn_public_id", where: "(forked_from_turn_public_id IS NOT NULL)"
    t.index ["id"], name: "index_conversations_reply_sources", where: "((spawn_node_id IS NOT NULL) OR (scheduled_job_id IS NOT NULL))"
    t.index ["parent_conversation_id", "spawn_label"], name: "index_conversations_on_parent_and_spawn_label", unique: true, where: "(spawn_label IS NOT NULL)"
    t.index ["parent_conversation_id"], name: "index_conversations_on_parent_conversation_id", where: "(parent_conversation_id IS NOT NULL)"
    t.index ["public_id"], name: "index_conversations_on_public_id", unique: true
    t.index ["runner_executor_id"], name: "index_conversations_on_runner_executor_id"
    t.index ["scheduled_job_id", "public_id"], name: "index_conversations_on_scheduled_job_id_and_public_id"
    t.index ["scheduled_job_id", "scheduled_for"], name: "index_conversations_scheduled_occurrence", unique: true, where: "(scheduled_job_id IS NOT NULL)"
    t.index ["search_terms"], name: "index_conversations_on_search_terms", using: :gin
    t.index ["spawn_node_id"], name: "index_conversations_on_spawn_node_id", unique: true, where: "(spawn_node_id IS NOT NULL)"
    t.index ["tombstoned_at", "id"], name: "index_conversations_reap_frontier", where: "(tombstoned_at IS NOT NULL)"
    t.index ["workspace_id", "id"], name: "index_conversations_on_workspace_id_and_id"
    t.index ["workspace_id", "last_activity_at", "id"], name: "index_conversations_on_workspace_activity", where: "(tombstoned_at IS NULL)"
    t.index ["workspace_id", "public_id"], name: "index_conversations_on_workspace_and_listable_public_id", where: "(tombstoned_at IS NULL)"
  end

  create_table "device_authorizations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "client_id", limit: 100, null: false
    t.string "agent_identifier", limit: 128
    t.string "agent_display_name", limit: 100
    t.string "requested_executor_display_name", limit: 100
    t.string "runner_identifier", limit: 128
    t.string "runner_display_name", limit: 100
    t.string "selected_assignment_scope", limit: 20
    t.string "device_code_lookup_id", limit: 24, null: false
    t.string "device_code_digest", null: false
    t.string "user_code", limit: 8, null: false
    t.integer "interval", default: 5, null: false
    t.datetime "last_polled_at"
    t.integer "exposure_count", default: 0, null: false
    t.string "status", limit: 20, default: "pending", null: false
    t.datetime "expires_at", null: false
    t.bigint "user_id"
    t.bigint "connected_by_id"
    t.integer "connected_by_authority_generation"
    t.uuid "expected_task_executor_public_id"
    t.integer "expected_credential_epoch"
    t.string "expected_task_executor_status", limit: 20
    t.bigint "task_executor_id"
    t.integer "user_authority_generation"
    t.bigint "access_token_id"
    t.bigint "refresh_token_id"
    t.string "request_ip", limit: 64
    t.string "request_user_agent", limit: 255
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "requested_executor_kind"
    t.index ["access_token_id"], name: "index_device_authorizations_on_access_token_id"
    t.index ["account_id"], name: "index_device_authorizations_on_account_id"
    t.index ["connected_by_id"], name: "index_device_authorizations_on_connected_by_id"
    t.index ["device_code_lookup_id"], name: "index_device_authorizations_on_device_code_lookup_id", unique: true
    t.index ["expected_task_executor_public_id", "status"], name: "index_device_authorizations_on_expected_executor_and_status"
    t.index ["expires_at", "id"], name: "index_device_authorizations_on_live_expiry", where: "((status)::text = ANY (ARRAY['pending'::text, 'connected'::text]))"
    t.index ["public_id"], name: "index_device_authorizations_on_public_id", unique: true
    t.index ["refresh_token_id"], name: "index_device_authorizations_on_refresh_token_id"
    t.index ["status"], name: "index_device_authorizations_on_status"
    t.index ["task_executor_id"], name: "index_device_authorizations_on_task_executor_id"
    t.index ["updated_at", "id"], name: "index_device_authorizations_on_terminal_retention", where: "((status)::text = ANY (ARRAY['canceled'::text, 'expired'::text, 'consumed'::text, 'invalidated'::text]))"
    t.index ["user_code"], name: "index_device_authorizations_on_user_code", unique: true, where: "((status)::text = ANY (ARRAY['pending'::text, 'connected'::text]))"
    t.index ["user_id"], name: "index_device_authorizations_on_user_id"
  end

  create_table "device_grant_verifications", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "device_authorization_id", null: false
    t.string "browser_context_digest", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_device_grant_verifications_on_account_id"
    t.index ["device_authorization_id", "browser_context_digest"], name: "index_device_grant_verifications_on_grant_and_context", unique: true
  end

  create_table "identities", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "email", limit: 255, null: false
    t.string "password_digest", null: false
    t.integer "credential_recovery_generation", default: 0, null: false
    t.datetime "local_recovery_pending_at"
    t.boolean "password_change_required", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_identities_on_account_id"
    t.index ["email"], name: "index_identities_on_email", unique: true
  end

  create_table "invitations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "inviter_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "email", limit: 255, null: false
    t.string "role", limit: 20, default: "member", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_delivery_requested_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invitations_on_account_id"
    t.index ["email"], name: "index_invitations_on_email", unique: true
    t.index ["inviter_id"], name: "index_invitations_on_inviter_id"
    t.index ["public_id"], name: "index_invitations_on_public_id", unique: true
  end

  create_table "member_recovery_authorizations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "identity_id", null: false
    t.bigint "user_id", null: false
    t.integer "generation", null: false
    t.string "lookup_id", limit: 24, null: false
    t.string "secret_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "superseded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_member_recovery_authorizations_on_account_id"
    t.index ["consumed_at", "id"], name: "index_member_recovery_authorizations_on_consumed_evidence", where: "(consumed_at IS NOT NULL)"
    t.index ["expires_at", "id"], name: "index_member_recovery_authorizations_on_unconsumed_expiry", where: "((consumed_at IS NULL) AND (superseded_at IS NULL))"
    t.index ["identity_id"], name: "index_member_recovery_authorizations_on_current", unique: true, where: "((consumed_at IS NULL) AND (superseded_at IS NULL))"
    t.index ["identity_id"], name: "index_member_recovery_authorizations_on_identity_id"
    t.index ["lookup_id"], name: "index_member_recovery_authorizations_on_lookup_id", unique: true
    t.index ["superseded_at", "id"], name: "index_member_recovery_authorizations_on_superseded_evidence", where: "(superseded_at IS NOT NULL)"
    t.index ["user_id"], name: "index_member_recovery_authorizations_on_user_id"
  end

  create_table "memory_document_versions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.text "content", null: false
    t.virtual "bytesize", type: :integer, as: "octet_length(content)", stored: true
    t.datetime "created_at", null: false
    t.index ["account_id"], name: "index_memory_document_versions_on_account_id"
  end

  create_table "memory_documents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id"
    t.bigint "workspace_id"
    t.bigint "user_id"
    t.string "name", limit: 128, null: false
    t.bigint "memory_document_version_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "description"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.index ["account_id"], name: "index_memory_documents_on_account_id"
    t.index ["conversation_id", "name"], name: "index_memory_documents_conversation_identity", unique: true, where: "(conversation_id IS NOT NULL)"
    t.index ["memory_document_version_id"], name: "index_memory_documents_on_memory_document_version_id"
    t.index ["public_id"], name: "index_memory_documents_on_public_id", unique: true
    t.index ["user_id", "name"], name: "index_memory_documents_user_identity", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["workspace_id", "name"], name: "index_memory_documents_workspace_identity", unique: true, where: "(workspace_id IS NOT NULL)"
  end

  create_table "model_invocation_attempts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "model_invocation_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.integer "ordinal", null: false
    t.string "admission_shape", limit: 16, null: false
    t.string "status", limit: 16, default: "prepared", null: false
    t.string "settlement_state", limit: 16, default: "not_applicable", null: false
    t.datetime "provider_started_at"
    t.datetime "terminal_at"
    t.datetime "deadline_at"
    t.uuid "consumer_public_id"
    t.uuid "payer_public_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_model_invocation_attempts_on_account_id"
    t.index ["deadline_at", "id"], name: "index_attempts_deadline_frontier", where: "((status)::text = ANY (ARRAY['prepared'::text, 'running'::text]))"
    t.index ["model_invocation_id", "ordinal"], name: "index_attempts_on_invocation_ordinal", unique: true
    t.index ["public_id"], name: "index_model_invocation_attempts_on_public_id", unique: true
    t.index ["status", "id"], name: "index_attempts_active_frontier", where: "((status)::text = ANY (ARRAY['prepared'::text, 'running'::text]))"
    t.index ["terminal_at", "id"], name: "index_attempts_settlement_frontier", where: "((settlement_state)::text = 'pending'::text)"
  end

  create_table "model_invocations", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "creating_user_id", null: false
    t.bigint "workspace_id"
    t.bigint "one_shot_id"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "workload", limit: 32, null: false
    t.string "purpose", limit: 32, null: false
    t.string "provider_id", limit: 64, null: false
    t.string "model_ref", limit: 128, null: false
    t.string "reasoning_effort", limit: 32
    t.jsonb "request_options", default: {}, null: false
    t.integer "admission_deadline_seconds", null: false
    t.integer "priority", default: 0, null: false
    t.string "internal_creation_key", limit: 64, null: false
    t.datetime "next_admission_at"
    t.string "status", limit: 16, default: "queued", null: false
    t.string "finish_quality", limit: 32
    t.datetime "canceled_at"
    t.datetime "terminal_at"
    t.string "cancellation_reason", limit: 32
    t.bigint "source_user_authority_generation"
    t.bigint "steward_shutdown_generation"
    t.string "failure_reason_key", limit: 64
    t.datetime "terminal_event_recorded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "conversation_id"
    t.bigint "agent_loop_id"
    t.string "failure_detail", limit: 256
    t.string "refusal_category", limit: 64
    t.index ["account_id", "internal_creation_key"], name: "idx_on_account_id_internal_creation_key_cc5f260292", unique: true
    t.index ["account_id", "terminal_at", "id"], name: "index_model_invocations_on_detail_retention", where: "((conversation_id IS NOT NULL) AND ((status)::text = ANY (ARRAY['completed'::text, 'failed'::text, 'canceled'::text, 'timed_out'::text])))"
    t.index ["agent_loop_id"], name: "index_model_invocations_on_agent_loop_id", where: "(agent_loop_id IS NOT NULL)"
    t.index ["conversation_id"], name: "index_model_invocations_on_conversation_id", where: "(conversation_id IS NOT NULL)"
    t.index ["created_at", "id"], name: "index_model_invocations_on_queued_scan", where: "((status)::text = 'queued'::text)"
    t.index ["creating_user_id", "id"], name: "index_model_invocations_on_creator_nonterminal", where: "((status)::text = ANY (ARRAY['queued'::text, 'running'::text]))"
    t.index ["id"], name: "index_model_invocations_on_terminal_events_owed", where: "(((status)::text = ANY (ARRAY['completed'::text, 'failed'::text, 'canceled'::text, 'timed_out'::text])) AND (terminal_event_recorded_at IS NULL) AND (one_shot_id IS NOT NULL))"
    t.index ["id"], name: "index_model_invocations_on_terminal_replies_owed", where: "(((status)::text = ANY (ARRAY['completed'::text, 'failed'::text, 'canceled'::text, 'timed_out'::text])) AND (terminal_event_recorded_at IS NULL) AND (conversation_id IS NOT NULL))"
    t.index ["id"], name: "index_model_invocations_on_terminal_steps_owed", where: "(((status)::text = ANY (ARRAY['completed'::text, 'failed'::text, 'canceled'::text, 'timed_out'::text])) AND (terminal_event_recorded_at IS NULL) AND (agent_loop_id IS NOT NULL))"
    t.index ["one_shot_id"], name: "index_model_invocations_on_one_shot_id"
    t.index ["provider_id", "workload"], name: "index_model_invocations_running_by_provider_workload", where: "((status)::text = 'running'::text)"
    t.index ["provider_id"], name: "index_model_invocations_running_by_provider", where: "((status)::text = 'running'::text)"
    t.index ["public_id"], name: "index_model_invocations_on_public_id", unique: true
    t.index ["workspace_id", "id"], name: "index_model_invocations_on_workspace_nonterminal", where: "((status)::text = ANY (ARRAY['queued'::text, 'running'::text]))"
    t.index ["workspace_id"], name: "index_model_invocations_on_workspace_id"
  end

  create_table "model_provider_credentials", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "provider_id", limit: 64, null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "material_kind", limit: 16, null: false
    t.text "secret", null: false
    t.text "refresh_secret"
    t.text "provider_account_identity"
    t.uuid "authorization_lineage_id"
    t.bigint "generation", default: 0, null: false
    t.datetime "rotated_at"
    t.datetime "refreshed_at"
    t.datetime "expires_at"
    t.boolean "reauthorization_required", default: false, null: false
    t.string "reauthorization_reason", limit: 64
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider_id"], name: "index_model_provider_credentials_on_account_id_and_provider_id", unique: true
    t.index ["account_id"], name: "index_model_provider_credentials_on_account_id"
    t.index ["public_id"], name: "index_model_provider_credentials_on_public_id", unique: true
  end

  create_table "model_provider_oauth_sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "provider_id", limit: 64, null: false
    t.bigint "issuing_user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "kind", limit: 16, null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.string "progress", limit: 24, null: false
    t.text "device_auth_id"
    t.text "user_code"
    t.string "verification_uri", limit: 255
    t.text "authorization_code"
    t.text "code_challenge"
    t.text "code_verifier"
    t.integer "poll_interval_seconds"
    t.datetime "poll_started_at"
    t.datetime "authorization_deadline_at"
    t.uuid "authorization_lineage_id", null: false
    t.uuid "source_credential_public_id"
    t.uuid "source_authorization_lineage_id"
    t.bigint "source_generation"
    t.string "outcome", limit: 32
    t.string "sanitized_reason", limit: 64
    t.datetime "next_action_at"
    t.string "semantic_exchange_kind", limit: 24
    t.integer "semantic_exchange_ordinal", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider_id"], name: "idx_on_account_id_provider_id_7b0f1f8ede"
    t.index ["account_id"], name: "index_model_provider_oauth_sessions_on_account_id"
    t.index ["issuing_user_id"], name: "index_model_provider_oauth_sessions_on_issuing_user_id"
    t.index ["next_action_at", "id"], name: "index_authorization_sessions_due", where: "((state)::text = 'pending'::text)"
    t.index ["public_id"], name: "index_model_provider_oauth_sessions_on_public_id", unique: true
    t.index ["updated_at", "id"], name: "index_authorization_sessions_retention", where: "((state)::text <> 'pending'::text)"
  end

  create_table "model_provider_oauth_tasks", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "model_provider_oauth_session_id", null: false
    t.string "exchange_kind", limit: 24, null: false
    t.datetime "claimed_at", null: false
    t.datetime "deadline_at", null: false
    t.string "state", limit: 16, default: "dispatching", null: false
    t.datetime "settled_at"
    t.string "normalized_status", limit: 32
    t.string "result_kind"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_model_provider_oauth_tasks_on_account_id"
    t.index ["deadline_at", "id"], name: "index_authorization_tasks_dispatching", where: "((state)::text = 'dispatching'::text)"
    t.index ["model_provider_oauth_session_id", "id"], name: "index_authorization_tasks_by_session"
  end

  create_table "model_provider_policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "provider_id", limit: 64, null: false
    t.boolean "enabled", default: false, null: false
    t.jsonb "model_overrides", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "provider_definition"
    t.index ["account_id", "provider_id"], name: "index_model_provider_policies_on_account_id_and_provider_id", unique: true
    t.index ["account_id"], name: "index_model_provider_policies_on_account_id"
  end

  create_table "model_provider_runtime_states", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "provider_id", limit: 64, null: false
    t.datetime "next_admission_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider_id"], name: "index_model_provider_runtime_states_on_account_and_provider", unique: true
  end

  create_table "model_usage_summaries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "subject_kind", limit: 32, null: false
    t.bigint "subject_id", null: false
    t.bigint "request_count", default: 0, null: false
    t.bigint "input_tokens", default: 0, null: false
    t.bigint "cache_read_tokens", default: 0, null: false
    t.bigint "cache_creation_tokens", default: 0, null: false
    t.bigint "output_tokens", default: 0, null: false
    t.bigint "reasoning_tokens", default: 0, null: false
    t.bigint "total_tokens", default: 0, null: false
    t.decimal "cost_amount", precision: 38, scale: 18, default: "0.0", null: false
    t.bigint "cost_known_request_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_model_usage_summaries_on_account_id"
    t.index ["subject_kind", "subject_id"], name: "index_model_usage_summaries_on_subject", unique: true
  end

  create_table "model_usage_time_buckets", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "bucket_kind", limit: 8, null: false
    t.datetime "bucket_start_at", null: false
    t.string "aggregation_key", limit: 64, null: false
    t.uuid "consumer_user_public_id", null: false
    t.uuid "payer_user_public_id"
    t.uuid "workspace_public_id"
    t.string "billing_subject_key", limit: 128
    t.string "provider_id", limit: 64, null: false
    t.string "catalog_model_ref", null: false
    t.string "workload", limit: 32, null: false
    t.string "status", limit: 16, null: false
    t.bigint "request_count", default: 0, null: false
    t.bigint "input_tokens", default: 0, null: false
    t.bigint "cache_read_tokens", default: 0, null: false
    t.bigint "cache_creation_tokens", default: 0, null: false
    t.bigint "output_tokens", default: 0, null: false
    t.bigint "reasoning_tokens", default: 0, null: false
    t.bigint "total_tokens", default: 0, null: false
    t.decimal "cost_amount", precision: 38, scale: 18, default: "0.0", null: false
    t.bigint "cost_known_request_count", default: 0, null: false
    t.datetime "rolled_up_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "bucket_kind", "bucket_start_at"], name: "index_model_usage_time_buckets_on_account_window"
    t.index ["account_id"], name: "index_model_usage_time_buckets_on_account_id"
    t.index ["bucket_kind", "bucket_start_at", "aggregation_key"], name: "index_model_usage_time_buckets_on_identity", unique: true
  end

  create_table "nexus_servers", force: :cascade do |t|
    t.string "boot_id", limit: 36, null: false
    t.string "host", limit: 255
    t.integer "pid"
    t.datetime "started_at", null: false
    t.datetime "heartbeat_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["boot_id"], name: "index_nexus_servers_on_boot_id", unique: true
    t.index ["heartbeat_at"], name: "index_nexus_servers_on_heartbeat_at"
  end

  create_table "one_shot_create_receipts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.bigint "acting_user_id", null: false
    t.bigint "one_shot_id", null: false
    t.string "workload", limit: 32, null: false
    t.string "idempotency_key", limit: 255, null: false
    t.string "request_digest", limit: 64, null: false
    t.jsonb "result", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "workspace_id", "acting_user_id", "idempotency_key"], name: "index_one_shot_create_receipts_on_replay_scope", unique: true
    t.index ["acting_user_id"], name: "index_one_shot_create_receipts_on_acting_user_id"
    t.index ["created_at", "id"], name: "index_one_shot_create_receipts_on_created_at_and_id"
    t.index ["one_shot_id"], name: "index_one_shot_create_receipts_on_one_shot_id", unique: true
    t.index ["workspace_id"], name: "index_one_shot_create_receipts_on_workspace_id"
  end

  create_table "one_shot_event_cursors", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "one_shot_id", null: false
    t.bigint "next_sequence", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["one_shot_id"], name: "index_one_shot_event_cursors_on_one_shot_id", unique: true
  end

  create_table "one_shot_event_items", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "one_shot_event_id", null: false
    t.bigint "one_shot_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.bigint "sequence", null: false
    t.string "item_type", limit: 40, null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["one_shot_event_id"], name: "index_one_shot_event_items_on_one_shot_event_id"
    t.index ["one_shot_id", "sequence"], name: "index_one_shot_event_items_on_sequence", unique: true
    t.index ["public_id"], name: "index_one_shot_event_items_on_public_id", unique: true
  end

  create_table "one_shot_events", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "one_shot_id", null: false
    t.string "idempotency_key", limit: 36, null: false
    t.index ["one_shot_id", "idempotency_key"], name: "index_one_shot_events_on_one_shot_key", unique: true
  end

  create_table "one_shots", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.bigint "creating_user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "workload", limit: 32, null: false
    t.datetime "tombstoned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "billing_subject_key", limit: 128
    t.uuid "billing_subject_public_id"
    t.index ["account_id"], name: "index_one_shots_on_account_id"
    t.index ["creating_user_id"], name: "index_one_shots_on_creating_user_id"
    t.index ["public_id"], name: "index_one_shots_on_public_id", unique: true
    t.index ["tombstoned_at", "id"], name: "index_one_shots_on_tombstoned_at_and_id", where: "(tombstoned_at IS NOT NULL)"
    t.index ["workspace_id", "id"], name: "index_one_shots_on_workspace_id_and_id"
    t.index ["workspace_id", "public_id"], name: "index_one_shots_on_workspace_and_listable_public_id", where: "(tombstoned_at IS NULL)"
  end

  create_table "prompt_documents", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id"
    t.bigint "user_id"
    t.string "slot", null: false
    t.string "role", null: false
    t.text "content", null: false
    t.virtual "bytesize", type: :integer, as: "octet_length(content)", stored: true
    t.integer "version", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_prompt_documents_on_account_id"
    t.index ["user_id", "slot"], name: "index_prompt_documents_user_identity", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["workspace_id", "slot"], name: "index_prompt_documents_workspace_identity", unique: true, where: "(workspace_id IS NOT NULL)"
  end

  create_table "refresh_token_families", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "access_token_name", limit: 160, null: false
    t.string "device_ip", limit: 64
    t.string "device_user_agent", limit: 255
    t.bigint "task_executor_id", null: false
    t.integer "credential_epoch", null: false
    t.integer "user_authority_generation"
    t.datetime "last_used_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_refresh_token_families_on_account_id"
    t.index ["last_used_at", "id"], name: "index_refresh_token_families_on_last_used_at_and_id"
    t.index ["public_id"], name: "index_refresh_token_families_on_public_id", unique: true
    t.index ["revoked_at"], name: "index_refresh_token_families_on_revoked_at"
    t.index ["task_executor_id", "credential_epoch"], name: "index_refresh_token_families_on_executor_epoch", unique: true
    t.index ["user_id"], name: "index_refresh_token_families_on_live_user", where: "(revoked_at IS NULL)"
    t.index ["user_id"], name: "index_refresh_token_families_on_user_id"
  end

  create_table "refresh_tokens", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id"
    t.bigint "refresh_token_family_id", null: false
    t.bigint "access_token_id"
    t.string "lookup_id", limit: 24, null: false
    t.string "secret_digest", null: false
    t.bigint "superseded_by_id"
    t.datetime "consumed_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_token_id"], name: "index_refresh_tokens_on_access_token_id"
    t.index ["account_id"], name: "index_refresh_tokens_on_account_id"
    t.index ["consumed_at", "id"], name: "index_refresh_tokens_on_consumed_at_and_id"
    t.index ["id"], name: "index_refresh_tokens_on_unrevoked_id", where: "(revoked_at IS NULL)"
    t.index ["lookup_id"], name: "index_refresh_tokens_on_lookup_id", unique: true
    t.index ["refresh_token_family_id", "id"], name: "index_refresh_tokens_on_family_and_id"
    t.index ["refresh_token_family_id", "id"], name: "index_refresh_tokens_on_unrevoked_family_and_id", where: "(revoked_at IS NULL)"
    t.index ["refresh_token_family_id"], name: "index_refresh_tokens_on_current_family", unique: true, where: "((consumed_at IS NULL) AND (revoked_at IS NULL))"
    t.index ["revoked_at", "id"], name: "index_refresh_tokens_on_revoked_at_and_id"
    t.index ["superseded_by_id"], name: "index_refresh_tokens_on_superseded_by_id"
    t.index ["user_id"], name: "index_refresh_tokens_on_user_id"
  end

  create_table "scheduled_jobs", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "creating_user_id", null: false
    t.bigint "answering_user_id", null: false
    t.uuid "public_id", null: false
    t.string "name"
    t.text "prompt", null: false
    t.jsonb "rule", default: {}, null: false
    t.string "provider_id", null: false
    t.string "model_ref", null: false
    t.string "reasoning_effort"
    t.jsonb "configuration", default: {}, null: false
    t.jsonb "tool_names"
    t.string "approval_mode"
    t.uuid "speaker_actor_public_id"
    t.uuid "source_agent_loop_public_id"
    t.string "source_task_key"
    t.string "status", default: "active", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "next_run_at"
    t.datetime "last_enqueued_at"
    t.uuid "last_input_public_id"
    t.bigint "last_execution_conversation_id"
    t.string "last_error_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_scheduled_jobs_on_account_id"
    t.index ["answering_user_id"], name: "index_scheduled_jobs_on_answering_user_id"
    t.index ["conversation_id", "public_id"], name: "index_scheduled_jobs_on_conversation_id_and_public_id"
    t.index ["conversation_id"], name: "index_scheduled_jobs_on_conversation_id"
    t.index ["creating_user_id"], name: "index_scheduled_jobs_on_creating_user_id"
    t.index ["last_execution_conversation_id"], name: "index_scheduled_jobs_on_last_execution_conversation_id"
    t.index ["next_run_at", "id"], name: "index_scheduled_jobs_due", where: "(((status)::text = 'active'::text) AND (next_run_at IS NOT NULL))"
    t.index ["public_id"], name: "index_scheduled_jobs_on_public_id", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "identity_id", null: false
    t.bigint "user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "kind", limit: 20, default: "browser", null: false
    t.string "lookup_id", limit: 24
    t.string "secret_digest"
    t.datetime "expires_at", null: false
    t.integer "user_authority_generation", null: false
    t.integer "identity_recovery_generation", null: false
    t.string "user_agent", limit: 255
    t.string "ip_address", limit: 64
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_sessions_on_account_id"
    t.index ["expires_at", "id"], name: "index_sessions_on_expires_at_and_id"
    t.index ["identity_id"], name: "index_sessions_on_identity_id"
    t.index ["lookup_id"], name: "index_sessions_on_lookup_id", unique: true, where: "(lookup_id IS NOT NULL)"
    t.index ["public_id"], name: "index_sessions_on_public_id", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "store_entries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id"
    t.bigint "conversation_id"
    t.bigint "user_id"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "namespace", limit: 80, null: false
    t.string "key", limit: 160, null: false
    t.jsonb "value"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_store_entries_on_account_id"
    t.index ["conversation_id", "namespace", "key"], name: "index_store_entries_conversation_identity", unique: true, where: "(conversation_id IS NOT NULL)"
    t.index ["public_id"], name: "index_store_entries_on_public_id", unique: true
    t.index ["user_id", "namespace", "key"], name: "index_store_entries_user_identity", unique: true, where: "(user_id IS NOT NULL)"
    t.index ["workspace_id", "namespace", "key"], name: "index_store_entries_workspace_identity", unique: true, where: "(workspace_id IS NOT NULL)"
  end

  create_table "task_executors", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "agent_profile_id"
    t.bigint "manager_id"
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "executor_kind", limit: 20, null: false
    t.string "display_name", limit: 100, null: false
    t.string "runner_identifier", limit: 128
    t.string "assignment_scope", limit: 20
    t.string "status", limit: 20, default: "active", null: false
    t.integer "credential_epoch", default: 1, null: false
    t.integer "applied_human_shutdown_generation", default: 0, null: false
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "served_tools", default: [], null: false
    t.jsonb "environment", default: {}, null: false
    t.string "presence_connection_id", limit: 36
    t.string "presence_server_id", limit: 36
    t.datetime "connected_at"
    t.jsonb "served_documents", default: [], null: false
    t.index ["account_id", "manager_id", "runner_identifier", "created_at", "id"], name: "index_task_executors_on_runner_identity", order: { created_at: :desc, id: :desc }
    t.index ["account_id", "manager_id", "runner_identifier"], name: "index_task_executors_on_live_runner_identity", unique: true, where: "(((executor_kind)::text = ANY (ARRAY['runner'::text, 'tools_provider'::text])) AND ((status)::text <> 'revoked'::text))"
    t.index ["agent_profile_id", "created_at", "id"], name: "index_task_executors_on_agent_profile_and_recency", order: { created_at: :desc, id: :desc }
    t.index ["agent_profile_id"], name: "index_task_executors_on_live_agent_application", unique: true, where: "(((executor_kind)::text = 'agent_application'::text) AND ((status)::text <> 'revoked'::text))"
    t.index ["id"], name: "index_task_executors_on_active_id", where: "((status)::text = 'active'::text)"
    t.index ["id"], name: "index_task_executors_on_revoked_id", where: "((status)::text = 'revoked'::text)"
    t.index ["manager_id"], name: "index_task_executors_on_manager_id"
    t.index ["public_id"], name: "index_task_executors_on_public_id", unique: true
  end

  create_table "usage_budget_entries", force: :cascade do |t|
    t.bigint "usage_budget_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.uuid "account_public_id", null: false
    t.uuid "user_public_id", null: false
    t.bigint "entry_sequence", null: false
    t.string "kind", limit: 32, null: false
    t.decimal "amount", precision: 38, scale: 18, null: false
    t.string "cost_unit", limit: 64, null: false
    t.uuid "actor_public_id"
    t.string "reason", limit: 255
    t.uuid "usage_record_public_id"
    t.string "operation_key", limit: 64, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_usage_budget_entries_on_public_id", unique: true
    t.index ["usage_budget_id", "entry_sequence"], name: "index_usage_budget_entries_on_sequence", unique: true
    t.index ["usage_budget_id", "operation_key"], name: "index_usage_budget_entries_on_operation_key", unique: true
    t.index ["usage_budget_id"], name: "index_usage_budget_entries_on_usage_budget_id"
  end

  create_table "usage_budgets", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "user_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.uuid "user_public_id", null: false
    t.string "user_kind", limit: 16, null: false
    t.datetime "starts_at", null: false
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.uuid "revoked_by_public_id"
    t.string "revoke_reason", limit: 255
    t.string "revoke_operation_key", limit: 64
    t.decimal "credited_amount", precision: 38, scale: 18, default: "0.0", null: false
    t.decimal "debited_amount", precision: 38, scale: 18, default: "0.0", null: false
    t.bigint "last_entry_sequence", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_usage_budgets_on_account_id"
    t.index ["public_id"], name: "index_usage_budgets_on_public_id", unique: true
    t.index ["user_id", "starts_at"], name: "index_usage_budgets_on_user_id_and_starts_at", unique: true
    t.index ["user_id"], name: "index_usage_budgets_on_user_id"
  end

  create_table "usage_records", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "idempotency_key", limit: 96, null: false
    t.uuid "model_invocation_public_id", null: false
    t.integer "attempt_ordinal", null: false
    t.uuid "consumer_user_public_id", null: false
    t.uuid "payer_user_public_id"
    t.uuid "workspace_public_id"
    t.uuid "one_shot_public_id"
    t.string "provider_id", limit: 64, null: false
    t.string "catalog_model_ref", null: false
    t.string "wire_model_id"
    t.string "provider_request_id", limit: 128
    t.string "workload", limit: 32, null: false
    t.string "purpose", limit: 32, null: false
    t.string "service_class", limit: 16, null: false
    t.string "admission_shape", limit: 16, null: false
    t.string "status", limit: 16, null: false
    t.string "error_code", limit: 64
    t.datetime "recorded_at", null: false
    t.jsonb "provider_usage"
    t.bigint "input_tokens"
    t.bigint "output_tokens"
    t.bigint "reasoning_tokens"
    t.bigint "cache_read_tokens"
    t.bigint "cache_creation_tokens"
    t.bigint "total_tokens"
    t.integer "duration_ms"
    t.integer "time_to_first_token_ms"
    t.jsonb "unit_pricing"
    t.decimal "cost_amount", precision: 38, scale: 18
    t.string "cost_unit", limit: 64
    t.string "billing_subject_key", limit: 128
    t.uuid "billing_subject_public_id"
    t.datetime "spend_settled_at"
    t.datetime "hourly_rolled_up_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "index_usage_records_on_idempotency_key", unique: true
    t.index ["account_id", "model_invocation_public_id", "attempt_ordinal"], name: "index_usage_records_on_attempt_identity", unique: true
    t.index ["account_id", "recorded_at", "id"], name: "index_usage_records_on_recorded_at"
    t.index ["account_id"], name: "index_usage_records_on_account_id"
    t.index ["public_id"], name: "index_usage_records_on_public_id", unique: true
    t.index ["recorded_at", "id"], name: "index_usage_records_on_unrolled", where: "(hourly_rolled_up_at IS NULL)"
    t.index ["recorded_at", "id"], name: "index_usage_records_on_unsettled", where: "(spend_settled_at IS NULL)"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.bigint "identity_id"
    t.string "display_name", limit: 100, null: false
    t.string "kind", limit: 20, null: false
    t.string "role", limit: 20, default: "member", null: false
    t.string "status", limit: 20, default: "active", null: false
    t.integer "authority_generation", default: 0, null: false
    t.integer "managed_resource_shutdown_generation", default: 0, null: false
    t.integer "applied_steward_shutdown_generation", default: 0, null: false
    t.bigint "steward_id"
    t.string "agent_identifier", limit: 128
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "tool_definitions"
    t.string "approval_mode"
    t.string "prompt_mechanism"
    t.jsonb "compaction_policy"
    t.jsonb "approval_rules"
    t.string "handle", limit: 32, null: false
    t.string "previous_handle", limit: 32
    t.datetime "handle_changed_at"
    t.jsonb "prompt_template"
    t.string "default_model", limit: 193
    t.bigint "derived_from_id"
    t.string "definition_scope"
    t.string "description", limit: 1024
    t.jsonb "lifecycle_hooks"
    t.string "fallback_model", limit: 193
    t.index ["account_id", "handle"], name: "index_users_on_account_id_and_handle", unique: true
    t.index ["account_id", "id"], name: "index_users_on_account_id_and_id", unique: true
    t.index ["derived_from_id"], name: "index_users_on_derived_from_id"
    t.index ["id"], name: "index_users_on_agent_profile_window", where: "((kind)::text = 'agent'::text)"
    t.index ["identity_id"], name: "index_users_on_identity_id", unique: true, where: "(identity_id IS NOT NULL)"
    t.index ["public_id"], name: "index_users_on_public_id", unique: true
    t.index ["steward_id", "agent_identifier"], name: "index_users_on_steward_id_and_agent_identifier", unique: true, where: "(agent_identifier IS NOT NULL)"
    t.index ["steward_id"], name: "index_users_on_steward_id"
  end

  create_table "workspace_command_receipts", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "workspace_id", null: false
    t.bigint "acting_user_id", null: false
    t.string "operation", limit: 32, null: false
    t.string "idempotency_key", limit: 255, null: false
    t.string "request_digest", limit: 64, null: false
    t.integer "response_status", null: false
    t.jsonb "response_body", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "acting_user_id", "idempotency_key"], name: "index_workspace_command_receipts_on_workspace_create_scope", unique: true, where: "((operation)::text = 'workspace_create'::text)"
    t.index ["account_id"], name: "index_workspace_command_receipts_on_account_id"
    t.index ["acting_user_id"], name: "index_workspace_command_receipts_on_acting_user_id"
    t.index ["created_at", "id"], name: "index_workspace_command_receipts_on_created_at_and_id"
    t.index ["workspace_id", "acting_user_id", "idempotency_key"], name: "index_workspace_command_receipts_on_store_entry_create_scope", unique: true, where: "((operation)::text = 'store_entry_create'::text)"
    t.index ["workspace_id", "id"], name: "index_workspace_command_receipts_on_workspace_id_and_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "creator_id", null: false
    t.bigint "owner_id", null: false
    t.uuid "public_id", default: -> { "uuidv7()" }, null: false
    t.string "name", limit: 100, null: false
    t.string "agent_identifier", limit: 128
    t.string "access_mode", limit: 20, default: "private", null: false
    t.jsonb "metadata", default: {}, null: false
    t.jsonb "tool_provider_overrides", default: {}, null: false
    t.string "state", limit: 20, default: "active", null: false
    t.datetime "archived_at"
    t.datetime "deleted_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "agent_identifier"], name: "index_workspaces_on_account_agent_identifier", where: "(agent_identifier IS NOT NULL)"
    t.index ["account_id"], name: "index_workspaces_on_account_id"
    t.index ["creator_id"], name: "index_workspaces_on_creator_id"
    t.index ["deleted_at", "id"], name: "index_workspaces_on_reapable_deleted_at_and_id", where: "((state)::text = 'deleted'::text)"
    t.index ["id"], name: "index_workspaces_on_transition_sweep", where: "((state)::text = ANY (ARRAY['archiving'::text, 'restoring'::text, 'deleting'::text]))"
    t.index ["owner_id"], name: "index_workspaces_on_owner_id"
    t.index ["public_id"], name: "index_workspaces_on_public_id", unique: true
  end

  add_foreign_key "access_tokens", "accounts"
  add_foreign_key "access_tokens", "refresh_token_families"
  add_foreign_key "access_tokens", "task_executors"
  add_foreign_key "access_tokens", "users"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "actors", "accounts"
  add_foreign_key "actors", "users"
  add_foreign_key "agent_loop_append_receipts", "accounts"
  add_foreign_key "agent_loop_append_receipts", "agent_loops"
  add_foreign_key "agent_loop_create_receipts", "accounts"
  add_foreign_key "agent_loop_create_receipts", "agent_loops"
  add_foreign_key "agent_loop_create_receipts", "users", column: "creating_user_id"
  add_foreign_key "agent_loop_create_receipts", "workspaces"
  add_foreign_key "agent_loop_edges", "accounts"
  add_foreign_key "agent_loop_edges", "agent_loop_nodes", column: "from_node_id"
  add_foreign_key "agent_loop_edges", "agent_loop_nodes", column: "to_node_id"
  add_foreign_key "agent_loop_edges", "agent_loops"
  add_foreign_key "agent_loop_nodes", "accounts"
  add_foreign_key "agent_loop_nodes", "agent_loop_nodes", column: "barrier_node_id", on_delete: :nullify
  add_foreign_key "agent_loop_nodes", "agent_loop_nodes", column: "expansion_parent_id"
  add_foreign_key "agent_loop_nodes", "agent_loops"
  add_foreign_key "agent_loop_nodes", "model_invocations", column: "selected_model_invocation_id"
  add_foreign_key "agent_loop_nodes", "task_executors", column: "addressed_executor_id", on_delete: :nullify
  add_foreign_key "agent_loop_nodes", "task_executors", column: "claimed_by_executor_id", on_delete: :nullify
  add_foreign_key "agent_loop_nodes", "users", column: "approved_by_user_id", on_delete: :nullify
  add_foreign_key "agent_loops", "accounts"
  add_foreign_key "agent_loops", "agent_loop_nodes", column: "deliverable_node_id"
  add_foreign_key "agent_loops", "conversation_turn_variants", on_delete: :nullify
  add_foreign_key "agent_loops", "task_executors", column: "runner_executor_id", on_delete: :nullify
  add_foreign_key "agent_loops", "users", column: "creating_user_id"
  add_foreign_key "agent_loops", "workspaces"
  add_foreign_key "billing_subjects", "accounts"
  add_foreign_key "billing_subjects", "users", column: "owning_user_id"
  add_foreign_key "content_bodies", "accounts"
  add_foreign_key "content_bodies", "agent_loop_nodes"
  add_foreign_key "content_bodies", "conversation_inputs"
  add_foreign_key "content_bodies", "conversation_turn_variants"
  add_foreign_key "content_bodies", "model_invocations"
  add_foreign_key "content_bodies", "one_shots"
  add_foreign_key "content_body_entries", "accounts"
  add_foreign_key "content_body_entries", "content_bodies", on_delete: :cascade
  add_foreign_key "content_body_entries", "content_fragments", on_delete: :restrict
  add_foreign_key "content_body_uploads", "content_bodies", on_delete: :cascade
  add_foreign_key "content_body_uploads", "content_uploads", on_delete: :restrict
  add_foreign_key "content_fragments", "accounts"
  add_foreign_key "content_uploads", "accounts"
  add_foreign_key "content_uploads", "task_executors", column: "creating_executor_id"
  add_foreign_key "content_uploads", "users", column: "creating_user_id"
  add_foreign_key "conversation_access_entries", "accounts"
  add_foreign_key "conversation_access_entries", "conversations"
  add_foreign_key "conversation_access_entries", "users"
  add_foreign_key "conversation_ancestries", "accounts"
  add_foreign_key "conversation_ancestries", "conversations", column: "ancestor_conversation_id", on_delete: :restrict
  add_foreign_key "conversation_ancestries", "conversations", on_delete: :cascade
  add_foreign_key "conversation_command_receipts", "accounts"
  add_foreign_key "conversation_command_receipts", "users", column: "acting_user_id"
  add_foreign_key "conversation_command_receipts", "workspaces", on_delete: :cascade
  add_foreign_key "conversation_event_cursors", "accounts"
  add_foreign_key "conversation_event_items", "accounts"
  add_foreign_key "conversation_event_items", "conversation_events"
  add_foreign_key "conversation_events", "accounts"
  add_foreign_key "conversation_inputs", "accounts"
  add_foreign_key "conversation_inputs", "actors", column: "speaker_actor_id"
  add_foreign_key "conversation_inputs", "conversation_turns", column: "steering_target_turn_id"
  add_foreign_key "conversation_inputs", "users", column: "answering_user_id"
  add_foreign_key "conversation_inputs", "users", column: "authoring_user_id"
  add_foreign_key "conversation_turn_overrides", "accounts"
  add_foreign_key "conversation_turn_overrides", "conversation_turns"
  add_foreign_key "conversation_turn_overrides", "conversations", on_delete: :cascade
  add_foreign_key "conversation_turn_variants", "accounts"
  add_foreign_key "conversation_turn_variants", "conversation_turn_variants", column: "origin_variant_id", on_delete: :nullify
  add_foreign_key "conversation_turn_variants", "conversation_turns"
  add_foreign_key "conversation_turn_variants", "model_invocations", on_delete: :nullify
  add_foreign_key "conversation_turns", "accounts"
  add_foreign_key "conversation_turns", "actors", column: "speaker_actor_id"
  add_foreign_key "conversation_turns", "conversation_turn_variants", column: "active_variant_id", on_delete: :nullify
  add_foreign_key "conversation_turns", "conversations"
  add_foreign_key "conversation_turns", "users", column: "answering_user_id"
  add_foreign_key "conversation_turns", "users", column: "control_owner_user_id"
  add_foreign_key "conversations", "accounts"
  add_foreign_key "conversations", "agent_loop_nodes", column: "spawn_node_id", on_delete: :nullify
  add_foreign_key "conversations", "conversation_turns", column: "active_turn_id", on_delete: :nullify
  add_foreign_key "conversations", "conversations", column: "parent_conversation_id", on_delete: :nullify
  add_foreign_key "conversations", "scheduled_jobs", on_delete: :nullify
  add_foreign_key "conversations", "task_executors", column: "runner_executor_id", on_delete: :nullify
  add_foreign_key "conversations", "users", column: "answering_user_id"
  add_foreign_key "conversations", "users", column: "creating_user_id"
  add_foreign_key "conversations", "workspaces"
  add_foreign_key "device_authorizations", "access_tokens", on_delete: :nullify
  add_foreign_key "device_authorizations", "accounts"
  add_foreign_key "device_authorizations", "refresh_tokens", on_delete: :nullify
  add_foreign_key "device_authorizations", "task_executors"
  add_foreign_key "device_authorizations", "users"
  add_foreign_key "device_authorizations", "users", column: "connected_by_id"
  add_foreign_key "device_grant_verifications", "accounts"
  add_foreign_key "device_grant_verifications", "device_authorizations", on_delete: :cascade
  add_foreign_key "identities", "accounts"
  add_foreign_key "invitations", "accounts"
  add_foreign_key "invitations", "users", column: "inviter_id"
  add_foreign_key "member_recovery_authorizations", "accounts"
  add_foreign_key "member_recovery_authorizations", "identities"
  add_foreign_key "member_recovery_authorizations", "users"
  add_foreign_key "memory_document_versions", "accounts"
  add_foreign_key "memory_documents", "accounts"
  add_foreign_key "memory_documents", "conversations"
  add_foreign_key "memory_documents", "memory_document_versions", on_delete: :restrict
  add_foreign_key "memory_documents", "users"
  add_foreign_key "memory_documents", "workspaces"
  add_foreign_key "model_invocation_attempts", "accounts"
  add_foreign_key "model_invocation_attempts", "model_invocations", on_delete: :restrict
  add_foreign_key "model_invocations", "accounts"
  add_foreign_key "model_invocations", "agent_loops"
  add_foreign_key "model_invocations", "conversations"
  add_foreign_key "model_invocations", "one_shots"
  add_foreign_key "model_invocations", "users", column: "creating_user_id"
  add_foreign_key "model_invocations", "workspaces"
  add_foreign_key "model_provider_credentials", "accounts"
  add_foreign_key "model_provider_oauth_sessions", "accounts"
  add_foreign_key "model_provider_oauth_sessions", "users", column: "issuing_user_id"
  add_foreign_key "model_provider_oauth_tasks", "accounts"
  add_foreign_key "model_provider_oauth_tasks", "model_provider_oauth_sessions", on_delete: :restrict
  add_foreign_key "model_provider_policies", "accounts"
  add_foreign_key "model_provider_runtime_states", "accounts", on_delete: :cascade
  add_foreign_key "model_usage_summaries", "accounts"
  add_foreign_key "model_usage_time_buckets", "accounts"
  add_foreign_key "one_shot_create_receipts", "accounts"
  add_foreign_key "one_shot_create_receipts", "one_shots"
  add_foreign_key "one_shot_create_receipts", "users", column: "acting_user_id"
  add_foreign_key "one_shot_create_receipts", "workspaces", on_delete: :cascade
  add_foreign_key "one_shot_event_cursors", "accounts"
  add_foreign_key "one_shot_event_cursors", "one_shots"
  add_foreign_key "one_shot_event_items", "accounts"
  add_foreign_key "one_shot_event_items", "one_shot_events"
  add_foreign_key "one_shot_event_items", "one_shots"
  add_foreign_key "one_shot_events", "accounts"
  add_foreign_key "one_shot_events", "one_shots"
  add_foreign_key "one_shots", "accounts"
  add_foreign_key "one_shots", "users", column: "creating_user_id"
  add_foreign_key "one_shots", "workspaces"
  add_foreign_key "prompt_documents", "accounts"
  add_foreign_key "prompt_documents", "users"
  add_foreign_key "prompt_documents", "workspaces"
  add_foreign_key "refresh_token_families", "accounts"
  add_foreign_key "refresh_token_families", "task_executors"
  add_foreign_key "refresh_token_families", "users"
  add_foreign_key "refresh_tokens", "access_tokens", on_delete: :nullify
  add_foreign_key "refresh_tokens", "accounts"
  add_foreign_key "refresh_tokens", "refresh_token_families"
  add_foreign_key "refresh_tokens", "refresh_tokens", column: "superseded_by_id", on_delete: :nullify
  add_foreign_key "refresh_tokens", "users"
  add_foreign_key "scheduled_jobs", "accounts"
  add_foreign_key "scheduled_jobs", "conversations", column: "last_execution_conversation_id", on_delete: :nullify
  add_foreign_key "scheduled_jobs", "conversations", on_delete: :cascade
  add_foreign_key "scheduled_jobs", "users", column: "answering_user_id"
  add_foreign_key "scheduled_jobs", "users", column: "creating_user_id"
  add_foreign_key "sessions", "accounts"
  add_foreign_key "sessions", "identities"
  add_foreign_key "sessions", "users"
  add_foreign_key "store_entries", "accounts"
  add_foreign_key "store_entries", "conversations"
  add_foreign_key "store_entries", "users"
  add_foreign_key "store_entries", "workspaces"
  add_foreign_key "task_executors", "accounts"
  add_foreign_key "task_executors", "users", column: "agent_profile_id"
  add_foreign_key "task_executors", "users", column: "manager_id"
  add_foreign_key "usage_budget_entries", "usage_budgets"
  add_foreign_key "usage_budgets", "accounts"
  add_foreign_key "usage_budgets", "users"
  add_foreign_key "usage_records", "accounts"
  add_foreign_key "users", "accounts"
  add_foreign_key "users", "identities"
  add_foreign_key "users", "users", column: "derived_from_id", on_delete: :nullify
  add_foreign_key "users", "users", column: "steward_id", on_delete: :nullify
  add_foreign_key "workspace_command_receipts", "accounts"
  add_foreign_key "workspace_command_receipts", "users", column: "acting_user_id"
  add_foreign_key "workspace_command_receipts", "workspaces", on_delete: :cascade
  add_foreign_key "workspaces", "accounts"
  add_foreign_key "workspaces", "users", column: "creator_id"
  add_foreign_key "workspaces", "users", column: ["account_id", "owner_id"], primary_key: ["account_id", "id"]
end
