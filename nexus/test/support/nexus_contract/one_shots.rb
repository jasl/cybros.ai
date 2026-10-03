module Nexus
  module Contract
    class << self
      private

        def one_shots
          basic, queued, full, truncated, failed, refused, switched, budget_spent, overloaded, with_files,
            with_vectors = one_shot_presenter_fixtures
          input_estimate = one_shot_input_estimate_fixture
          list_fixture = {
            "one_shots" => [basic],
            "pagination" => { "next_after" => nil },
          }
          events_fixture = {
            "events" => [one_shot_event_fixture],
            # `next_after` names where the PAGE stopped; `watermark` names where
            # the STREAM was when the request was served. A follower drains to
            # the second, not the first — and unlike `next_after` it is present
            # on an empty page, which is the case that needs it most.
            "pagination" => {
              "next_after" => "b25lLXNob3QtY3Vyc29yLTE",
              "watermark" => 4,
            },
          }
          realtime_subscription = {
            "channel" => "AgentAPI::V1::OneShotEventsChannel",
            "workspace_id" => "01900000-0000-7000-8000-000000000001",
            "one_shot_id" => basic.fetch("public_id"),
            "items" => "events",
          }
          terminal_wake = one_shot_event_fixture.merge(
            "type" => "result",
            "payload" => {
              "result" => {
                "status" => "completed",
                "one_shot_public_id" => basic.fetch("public_id"),
              },
            }
          )

          {
            "workloads" => Nexus::ModelWorkloads::ALL.sort,
            "statuses" => ModelInvocation::STATUSES.sort,
            "terminal_statuses" => ModelInvocation::TERMINAL_STATUSES.sort,
            "event_types" => OneShotEventItem::ITEM_TYPES.sort,
            "retention_period_days" => (OneShot::RETENTION_PERIOD / 86_400).to_i,
            "list_envelope" => list_fixture.keys,
            "singular_envelope" => %w[one_shot],
            "events_envelope" => events_fixture.keys,
            "realtime_path" => "/agent_api/v1/cable",
            "realtime_envelope" => %w[event],
            "realtime_items" => AgentAPI::V1::OneShotEventsChannel::FEEDS.keys,
            "realtime_default_items" => "events",
            "realtime_lifecycle_event_types" =>
              RealtimeEvents::Broadcast::LIFECYCLE_TYPES.fetch("one_shot"),
            "terminal_wake_result_projection" =>
              terminal_wake.dig("payload", "result").keys,
            "input_estimate_envelope" => input_estimate.keys,
            "pagination" => list_fixture.fetch("pagination").keys,
            # THREE shapes, not two. Basic appears only inside the list
            # envelope; a singular read always renders Full — and before the
            # run is terminal that Full carries no `result`, which is the
            # queued shape a caller actually meets first.
            "basic_projection" => basic.keys,
            "queued_projection" => queued.keys,
            "full_projection_adds" => full.keys - basic.keys,
            "model_projection" => basic.fetch("model").keys,
            "input_estimate_projection" => input_estimate.fetch("input_estimate").keys,
            "input_estimate_projection_required" =>
              %w[input_tokens tokenizer_exact model],
            "result_projection" => full.fetch("result").keys,
            # The result envelope compacts, and `status` is the ONE member every
            # terminal result carries: `output_text` is the text workloads'
            # answer alone (absent on image and embedding runs), and `usage` and
            # `timing` are the terminal attempt's receipt, which a run cut
            # before any attempt started never wrote. Each optional member's
            # presence is its own signal.
            "result_projection_required" => %w[status],
            "result_projection_optional" =>
              %w[output_text usage timing finish_quality refusal_category error reasoning output_files embeddings
                 model_change],
            # What the run's latest execution replaced when the creator's
            # declared fallback ran a declined run again: the switch's own
            # `{from, to, reason, category?}`, the category absent when the
            # provider named none.
            "model_change_projection" => switched.dig("result", "model_change").keys,
            "model_change_projection_required" => %w[from to reason],
            # The embedding workload's typed answer (C-U2): `[{index, vector}]`
            # in the provider's order, and `output_text` ABSENT there.
            "embedding_projection" => %w[index vector],
            # Only workloads that produce bytes expose these entries. Each download uses its output
            # index; there is no separate per-file identifier.
            "output_file_projection" => %w[index filename content_type byte_size],
            # USAGE COMPACTS TOO, and far harder than the envelope above:
            # every counter on a receipt is nullable, so a real run renders a
            # SUBSET of this list. Only the receipt's own id and the
            # cost-completeness flag are guaranteed — a consumer that fetched
            # `total_tokens` would break on the first provider that does not
            # report one. `timing` compacts to nothing at all and then the
            # member itself is absent.
            "usage_projection" => full.dig("result", "usage").keys,
            "usage_projection_required" => %w[usage_record_public_id cost_complete],
            "timing_projection" => full.dig("result", "timing").keys,
            "timing_projection_required" => [],
            # The SUMMARY is the exception: its counters default to zero rather
            # than to nil, so only the ratio can be absent.
            "usage_summary_projection" => full.fetch("usage_summary").keys,
            "usage_summary_projection_required" =>
              full.fetch("usage_summary").keys - %w[cache_hit_rate],
            "event_projection" => events_fixture.fetch("events").first.keys,
            "list_filters" => %w[workload order after limit],
            "list_directions" => AgentAPI::KeysetPagination::DIRECTIONS.keys,
            "events_filters" => %w[after limit],
            "events_pagination" => events_fixture.fetch("pagination").keys,
            "events_default_limit" => AgentAPI::V1::Workspaces::OneShots::EventsController::DEFAULT_LIMIT,
            "events_max_limit" => AgentAPI::V1::Workspaces::OneShots::EventsController::MAX_LIMIT,
            "error_codes" => ONE_SHOT_ERROR_STATUSES.keys,
            "error_statuses" => ONE_SHOT_ERROR_STATUSES,
            # The refusal vocabulary is OPEN by construction (see the constant
            # above): this is one specimen, not the set.
            #
            # AND THE STATUS IS NOT FLAT. A refusal carries 422 unless its code
            # belongs to the family, in which case the family's published
            # status wins — a storage-bound refusal reaching this path from
            # `ContentBodies::Replace` is `content_too_large`, and that is a
            # 413 here as it is everywhere. Stating a bare 422 made this
            # surface promise something it does not do, and a status that
            # depends on the code is exactly what `errors.json` exists to let
            # a caller resolve.
            "refusal_error_status" => 422,
            "refusal_status_exception" => "family_codes carry their errors.json status",
            "refusal_specimen" => "unknown_model",
            "valid_fixture" => { "one_shot" => full },
            "valid_basic_fixture" => { "one_shot" => basic },
            "valid_queued_fixture" => { "one_shot" => queued },
            "valid_truncated_fixture" => { "one_shot" => truncated },
            "valid_image_fixture" => { "one_shot" => with_files },
            "valid_embedding_fixture" => { "one_shot" => with_vectors },
            "valid_failed_fixture" => { "one_shot" => failed },
            "valid_refused_fixture" => { "one_shot" => refused },
            "valid_switched_fixture" => { "one_shot" => switched },
            "valid_budget_spent_fixture" => { "one_shot" => budget_spent },
            "valid_overloaded_fixture" => { "one_shot" => overloaded },
            "valid_list_fixture" => list_fixture,
            "valid_events_fixture" => events_fixture,
            "valid_input_estimate_fixture" => input_estimate,
            "valid_event_fixture" => events_fixture.fetch("events").first,
            "valid_realtime_subscription_fixture" => realtime_subscription,
            "valid_realtime_event_fixture" => { "event" => one_shot_event_fixture },
            "valid_terminal_wake_fixture" => { "event" => terminal_wake },
            "unknown_realtime_items_fixture" =>
              realtime_subscription.merge("items" => UNKNOWN_VALUE_FIXTURE),
            "valid_create_request" => {
              "one_shot" => {
                "workload" => "text_generation",
                "model" => { "model" => "dev/text", "reasoning_effort" => "medium" },
                "input" => "Say hi",
                "configuration" => { "temperature" => 0.2 },
                "upload_public_ids" => [],
                "billing_subject" => nil,
              },
            },
            "valid_create_status" => 202,
            "valid_replay_status" => 200,
            "valid_input_estimate_request" => {
              "input_estimate" => {
                "workload" => "text_generation",
                "model" => { "model" => "dev/text", "reasoning_effort" => "medium" },
                "input" => "Say hi",
                "configuration" => { "temperature" => 0.2 },
                "upload_public_ids" => [],
              },
            },
            "valid_workload_filter_request" => { "workload" => "embedding" },
            "valid_delete_fixture" => { "status" => 204, "body" => nil },
            "valid_error_fixture" =>
              api_error_fixture("not_terminal", ONE_SHOT_ERROR_STATUSES.fetch("not_terminal")),
            "unknown_workload_fixture" => basic.merge("workload" => UNKNOWN_VALUE_FIXTURE),
            "unknown_workload_filter_request" => { "workload" => UNKNOWN_VALUE_FIXTURE },
            # Full-shaped, because a singular read is where a caller meets a
            # status — the workload specimen above stays Basic for the list.
            "unknown_status_fixture" => queued.merge("status" => UNKNOWN_VALUE_FIXTURE),
            "unknown_event_type_fixture" =>
              one_shot_event_fixture.merge("type" => UNKNOWN_VALUE_FIXTURE),
            "unknown_refusal_fixture" => api_error_fixture(UNKNOWN_VALUE_FIXTURE, 422),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "unknown_value_behavior" => "carry_unknown_response",
            "unknown_field_behavior" => "ignore",
            "terminality_signal" => "result_present",
          }
        end

        def one_shot_input_estimate_fixture
          reasoning_type = Data.define(:effort)
          selection_type = Data.define(:provider_id, :model_ref, :reasoning)
          estimate = OneShots::InputEstimate::Estimate.new(
            input_tokens: 24,
            tokenizer_exact: true,
            catalog_input_token_limit: 128_000,
            advisory_input_token_limit: 100_000,
            selection: selection_type.new(
              provider_id: "dev",
              model_ref: "text",
              reasoning: reasoning_type.new(effort: "medium")
            )
          )

          {
            "input_estimate" => stringify_keys(
              AgentAPI::OneShotInputEstimatePresenter.full(estimate)
            ),
          }
        end

        # Basic comes from the presenter itself, over a duck type carrying
        # exactly the members it reads — so a renamed projection key fails here
        # rather than reaching an SDK. The Full fixture's two additions cannot
        # take that road: `usage_summary` is a query and `result` reads an
        # invocation's bodies and receipts, so they are composed here and PINNED
        # AGAINST THE LIVE WIRE by the one-shot request test, which renders a
        # real terminal run and compares its key sets to this pack.
        def one_shot_presenter_fixtures
          invocation_type = Data.define(:provider_id, :model_ref, :reasoning_effort)
          one_shot_type = Data.define(
            :public_id, :workload, :status, :model_invocation,
            :billing_subject_key, :created_at, :updated_at
          )
          one_shot = one_shot_type.new(
            public_id: "01900000-0000-7000-8000-000000000060",
            workload: "text_generation",
            status: "completed",
            model_invocation: invocation_type.new(
              provider_id: "dev", model_ref: "dev/text",
              reasoning_effort: "medium"
            ),
            billing_subject_key: nil,
            created_at: Time.utc(2026, 7, 30),
            updated_at: Time.utc(2026, 7, 30, 0, 0, 12)
          )
          basic = stringify_keys(AgentAPI::OneShotPresenter.basic(one_shot))
          usage = one_shot_usage_fixture
          timing = { "duration_ms" => 12_480, "time_to_first_token_ms" => 310 }
          clean = {
            "status" => "completed",
            "output_text" => "Hi.",
            "usage" => usage,
            "timing" => timing,
          }

          terminal = basic.merge("usage_summary" => one_shot_usage_summary_fixture)
          # No `result`, and the summary counting zero requests: the shape the
          # 202 renders, where absence of `result` IS "not finished".
          queued = basic.merge(
            "status" => "queued",
            "usage_summary" => one_shot_zero_usage_summary_fixture
          )
          full = terminal.merge("result" => clean)
          # A cut-off answer is a SUCCESS with a caveat: the quality sits beside
          # the status and `error` stays absent.
          truncated = terminal.merge("result" => clean.merge("finish_quality" => "output_budget_exhausted"))
          failed = terminal.merge(
            "status" => "failed",
            "result" => {
              "status" => "failed",
              "usage" => usage,
              "timing" => timing,
              "error" => { "code" => "provider_error" },
            }
          )
          # A DECLINED ANSWER FAILED THE RUN: the call completed and was billed
          # (its usage stays), but the run has no answer — `error.code` says why,
          # the quality and the provider's category ride beside the status, and
          # there is no `output_text`.
          refused = terminal.merge(
            "status" => "failed",
            "result" => {
              "status" => "failed",
              "finish_quality" => "refused",
              "refusal_category" => "cyber",
              "usage" => usage,
              "timing" => timing,
              "error" => { "code" => "model_refused" },
            }
          )
          # A DECLINED RUN THE CREATOR'S FALLBACK ANSWERED: the run reads its
          # latest execution — the fallback's model, its answer, its receipt —
          # and `model_change` says what that execution replaced.
          switched = terminal.merge(
            "model" => basic.fetch("model").merge("provider_id" => "dev", "model_ref" => "fallback"),
            "result" => clean.merge("model_change" => {
              "from" => "dev/primary", "to" => "dev/fallback",
              "reason" => "model_refused", "category" => "cyber",
            })
          )
          # THE BUDGET IS A CAVEAT BESIDE THE CODE, never instead of it. When
          # this side's retry policy is what ended the run, `code` still names
          # what the provider said on the last attempt — "retry later" and "fix
          # your request" are the two answers a caller has to tell apart — and
          # the boolean says the run stopped because the budget was spent. It
          # is present only when it applies, like `finish_quality`.
          budget_spent = terminal.merge(
            "status" => "failed",
            "result" => {
              "status" => "failed",
              "usage" => usage,
              "timing" => timing,
              "error" => { "code" => "provider_http_error", "attempt_budget_spent" => true },
            }
          )
          # OVERLOADED ON EVERY ATTEMPT the budget spent (503, 529, the streamed
          # `overloaded_error`): the provider's own word is the code, with the
          # spent budget beside it — the run's key when no declared fallback
          # answered it.
          overloaded = budget_spent.merge(
            "result" => budget_spent.fetch("result").merge(
              "error" => { "code" => "provider_overloaded", "attempt_budget_spent" => true }
            )
          )

          # An image run: the same envelope, plus the files it produced. Its
          # `output_text` is whatever prose the provider sent alongside — a
          # revised prompt, usually nothing — never a handle on the bytes.
          with_files = terminal.merge(
            "workload" => "image_generation",
            "result" => clean.except("output_text").merge("output_files" => [
              {
                "index" => 0,
                "filename" => "01900000-0000-7000-8000-000000000060-image-output-1",
                "content_type" => "image/png",
                "byte_size" => 128,
              },
            ])
          )

          # An embedding run: the vectors typed as `[{index, vector}]` (C-U2),
          # and no `output_text` — the answer is not prose.
          with_vectors = terminal.merge(
            "workload" => "embedding",
            "result" => clean.except("output_text").merge("embeddings" => [
              { "index" => 0, "vector" => [0.1, 0.2, 0.3] },
            ])
          )

          [basic, queued, full, truncated, failed, refused, switched, budget_spent, overloaded, with_files, with_vectors]
        end

        def one_shot_usage_fixture
          {
            "usage_record_public_id" => "01900000-0000-7000-8000-000000000061",
            "input_tokens" => 1_200,
            "cache_read_tokens" => 300,
            "uncached_input_tokens" => 900,
            "cache_creation_tokens" => 0,
            "cache_hit_rate" => 0.25,
            "output_tokens" => 64,
            "reasoning_tokens" => 16,
            "total_tokens" => 1_264,
            "cost_amount" => "0.0042",
            "cost_unit" => "USD",
            "cost_complete" => true,
          }
        end

        # The cumulative cache across the whole attempt history, which is why
        # it counts requests and names no single receipt.
        def one_shot_usage_summary_fixture
          { "request_count" => 1 }.merge(one_shot_usage_fixture.except("usage_record_public_id", "cost_unit"))
        end

        # Zero requests is a TRUE STATEMENT, not an absence — the summary is
        # always present, so a caller never branches on whether it is there.
        def one_shot_zero_usage_summary_fixture
          one_shot_usage_summary_fixture
            .transform_values { |value| value.is_a?(String) ? "0.0" : 0 }
            .merge("cache_hit_rate" => nil, "cost_complete" => true).compact
        end

        def one_shot_event_fixture
          {
            "public_id" => "01900000-0000-7000-8000-000000000062",
            # OneShot-local, from 1, contiguous. A follower orders and merges
            # the two transports by this; the cursor beside it stays opaque and
            # is only ever handed back to a replay read.
            "sequence" => 4,
            "cursor" => "b25lLXNob3QtY3Vyc29yLTE",
            "type" => "text_delta",
            "resource" => {
              "type" => "one_shot",
              "public_id" => "01900000-0000-7000-8000-000000000060",
            },
            "occurred_at" => "2026-07-30T00:00:03.500Z",
            "payload" => { "text" => "Hi." },
          }
        end
    end
  end
end
