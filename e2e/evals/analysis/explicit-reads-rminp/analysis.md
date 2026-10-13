# explicit-reads-rminp — analysis

## Provenance (the stamp is the header)

```text
mode=real
screen=explicit-reads-rminp
definition_sha256=27bc183b90f191fa4b3dcf1f12a84c33a1b7d6eefb765ae42be13f20d1a70548
design=docs/plans/2026-09-28-explicit-reads-rminp-screen.md Registered
design_section_sha256=0bb6934504b575dc58cf879147b89da87251ae5cab7e5eae342e25e728f14382
corpus.v13-15=fdb1ff5f5678468d7f2a386622def728df16603eabfafbb131b3e5b1de2b9848
corpus.v16=ae956c6bb3caef1965f44a3c51f3ead241b83678f5b947b5da8bbfebfcc2359c
corpus.nul=fafdaf31a6bce7238ece605a9ab7f4df3a34f65f35428b2f946e206f34766180
corpus.declarations=7cee0cade3a9f598bc4d1992a052ebdb5e6b4f282cd8828e3c5e63d4d8b172ad
corpus.door=620043fe91beba3b3a83d7524ebae7c339fdf88198844b8d3f0b2034210b73ef
head.with=d703d690efd8bec88927e4e1037e649b6e279873
head.without=a3cde714901d7143b4048dad62a6f53132db35a1
tree.with.root=/Users/jasl/Workspaces/cybros-ai.alt2-reads
tree.with.state=d703d690efd8bec88927e4e1037e649b6e279873 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 23750efcf83b3b927847bf4c1ec97f8b59a5545396cd5b1eb5cf0978e270a272
tree.without.root=/Users/jasl/Workspaces/cybros-ai.alt2
tree.without.state=a3cde714901d7143b4048dad62a6f53132db35a1 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ceea0e288c6f4113da590818a11f2fb6c394f5a2fa2e171d664d8bf6f617be2c
base=a3cde714901d7143b4048dad62a6f53132db35a1
main_head=a3cde714901d7143b4048dad62a6f53132db35a1
transport_diff=none
allowlist_diff=.ai/nexus.md agents/rho/rho/lib/rho/until.rb agents/rho/rho/test/extensions/until_test.rb agents/rho/rho/test/until_test.rb contracts/nexus/v1/profiles.json docs/agent-api/v1/agent_loops.md docs/orchestration.md docs/plans/2026-09-06-authoring-final-decision.md docs/plans/2026-09-06-dataflow-evaluation/verdict.md docs/plans/2026-09-06-loop-authoring-design.md docs/plans/2026-09-20-append-material-frontier.md docs/plans/2026-09-21-append-material-implementation.md docs/plans/2026-09-21-result-driven-dag-design.md docs/plans/2026-09-23-compose-weak-models-plan.md docs/plans/2026-09-26-explicit-reads-design.md docs/plans/DEFERRALS.md docs/plans/README.md e2e/.rubocop.yml e2e/evals/bench.yml e2e/evals/tasks/compose-background-suite/RATIONALE.md e2e/evals/tasks/compose-background-suite/expected.rb e2e/evals/tasks/compose-grep-then-edit/RATIONALE.md e2e/evals/tasks/compose-grep-then-edit/expected.rb e2e/evals/tasks/compose-race-anon/RATIONALE.md e2e/evals/tasks/compose-race/RATIONALE.md e2e/evals/tasks/compose-race/expected.rb e2e/evals/tasks/compose-rendezvous/RATIONALE.md e2e/evals/tasks/compose-rendezvous/expected.rb e2e/evals/tasks/compose-review-angles/RATIONALE.md e2e/evals/tasks/compose-review-angles/expected.rb e2e/evals/tasks/compose-three-stage-pairing/RATIONALE.md e2e/evals/tasks/compose-three-stage-pairing/expected.rb e2e/evals/tasks/compose-two-source-fan-in/RATIONALE.md e2e/evals/tasks/compose-two-source-fan-in/expected.rb e2e/evals/tasks/until-ladder/RATIONALE.md e2e/evals/tasks/workflow-barrier-free-pipeline/RATIONALE.md e2e/evals/tasks/workflow-barrier-free-pipeline/expected.rb e2e/support/compose_bench.rb e2e/support/compose_bench/buckets.rb e2e/support/compose_bench/delivery.rb e2e/support/compose_bench/delivery_kernel.rb e2e/support/compose_bench/endpoints.rb e2e/support/compose_bench/executed.rb e2e/support/compose_bench/objectives.rb e2e/support/compose_bench/picture.rb e2e/support/compose_bench/probe.rb e2e/support/compose_bench/replay.rb e2e/support/compose_bench/replay_kernel.rb e2e/support/compose_bench/rows.rb e2e/support/compose_bench/scoring.rb e2e/support/compose_bench/shape.rb e2e/support/evals/composed_reads.rb e2e/support/evals/drawing.rb e2e/support/evals/member_plane.rb e2e/support/evals/predicates.rb e2e/support/evals/race_followers.rb e2e/support/evals/race_losers.rb e2e/support/evals/sealed_request.rb e2e/support/evals/trace.rb e2e/support/fixtures/executed_plans/member_continuation_read.json e2e/support/fixtures/executed_plans/member_continuation_rounds.json e2e/support/fixtures/executed_plans/race.json e2e/support/fixtures/executed_plans/results_wiring.json e2e/support/fixtures/executed_plans/value_stages_in_a_race.json e2e/support/fixtures/executed_plans/whole_plan_wrapper.json e2e/support/fixtures/executed_plans/wrapped_rendezvous.json e2e/support/fixtures/screen/fake/screen.yml e2e/support/fixtures/screen/pairs/compose-reads/compose/with/records.jsonl e2e/support/fixtures/screen/pairs/compose-reads/compose/without/records.jsonl e2e/support/gallery/shapes.rb e2e/support/gallery/thread.rb e2e/support/journey_groups.rb e2e/test/bench_client_harness_test.rb e2e/test/compose_bench_buckets_harness_test.rb e2e/test/compose_bench_delivery_harness_test.rb e2e/test/compose_bench_endpoints_harness_test.rb e2e/test/compose_bench_executed_harness_test.rb e2e/test/compose_bench_harness.rb e2e/test/compose_bench_heartbeat_harness_test.rb e2e/test/compose_bench_inline_harness_test.rb e2e/test/compose_bench_lowering_harness_test.rb e2e/test/compose_bench_pictures_harness_test.rb e2e/test/compose_bench_probe_harness_test.rb e2e/test/compose_bench_replay_harness_test.rb e2e/test/compose_bench_rows_harness_test.rb e2e/test/compose_bench_usable_harness_test.rb e2e/test/compose_matrix_probe_test.rb e2e/test/conversation_background_test.rb e2e/test/conversation_result_dag_test.rb e2e/test/evals_bench_test.rb e2e/test/evals_drawings.rb e2e/test/evals_expected_test.rb e2e/test/evals_member_plane_test.rb e2e/test/evals_predicates_test.rb e2e/test/gallery_shapes_test.rb e2e/test/manual_client_harness_test.rb e2e/test/screen_analysis_harness_test.rb e2e/test/screen_definition_harness_test.rb e2e/test/until_test.rb nexus/app/models/agent_loop_node.rb nexus/app/services/agent_loops/compose/run.rb nexus/app/services/agent_loops/delivery.rb nexus/app/services/agent_loops/expansion_ownership.rb nexus/app/services/agent_loops/input_composition.rb nexus/app/services/agent_loops/input_composition/sources.rb nexus/app/services/agent_loops/mail.rb nexus/app/services/agent_loops/repeat_brake.rb nexus/app/services/agent_loops/task_result_envelope.rb nexus/app/services/agent_loops/task_tool/run.rb nexus/app/services/agent_loops/task_waits/observe.rb nexus/app/services/agent_loops/tasks/append.rb nexus/app/services/agent_loops/tasks/append/splice.rb nexus/app/services/agent_loops/tasks/compile.rb nexus/app/services/agent_loops/wake_continuation.rb nexus/app/services/conversations/compaction/fallback.rb nexus/app/services/conversations/compaction/serialize.rb nexus/db/migrate/20260914150002_create_nexus_schema.rb nexus/db/schema.rb nexus/lib/nexus/compose/builder.js nexus/lib/nexus/compose/reads.rb nexus/lib/nexus/compose/run.js nexus/lib/nexus/tool_registry/graph.rb nexus/test/lib/nexus/compose/evaluator_test.rb nexus/test/lib/nexus/compose/reads_test.rb nexus/test/lib/nexus/compose/script_stage_test.rb nexus/test/lib/nexus/tool_registry_test.rb nexus/test/presenters/agent_api/agent_loop_graph_presenter_test.rb nexus/test/services/agent_loops/append_material_test.rb nexus/test/services/agent_loops/append_script_boundary_test.rb nexus/test/services/agent_loops/append_test.rb nexus/test/services/agent_loops/compile_test.rb nexus/test/services/agent_loops/compose_detached_test.rb nexus/test/services/agent_loops/compose_failure_test.rb nexus/test/services/agent_loops/compose_test.rb nexus/test/services/agent_loops/continuation_authors_test.rb nexus/test/services/agent_loops/dag_expressiveness_test.rb nexus/test/services/agent_loops/delivery_test.rb nexus/test/services/agent_loops/detached_material_test.rb nexus/test/services/agent_loops/doctrine_experiments_test.rb nexus/test/services/agent_loops/input_composition_loading_test.rb nexus/test/services/agent_loops/input_composition_recovery_test.rb nexus/test/services/agent_loops/input_composition_test.rb nexus/test/services/agent_loops/race_results_test.rb nexus/test/services/agent_loops/scripts/lifecycle_test.rb nexus/test/services/agent_loops/scripts/model_result_test.rb nexus/test/services/agent_loops/scripts/run_test.rb nexus/test/services/agent_loops/selected_result_recovery_test.rb nexus/test/services/agent_loops/selected_results_test.rb nexus/test/services/agent_loops/task_lifetime_test.rb nexus/test/services/agent_loops/task_references_test.rb nexus/test/services/agent_loops/wake_continuation_test.rb nexus/test/services/conversations/compaction/arm_test.rb nexus/test/test_helpers/compose_test_helper.rb nexus/test/test_helpers/refused_step_test_helper.rb sdks/ruby/README.md
load_1min=11.85
load_ceiling=16.0
bytes.without.compose_bench.R-WO.nexus=7994 1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6
bytes.without.task_probe.compose.nexus=7994 1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6
bytes.without.task_probe.task.nexus=2934 4b2a4aae71ec5ff42978a6ef6ed7de2dbc7349f9745cd3415a876f1408055113
bytes.without.compose_bench.R-WO.claude=7997 c568c9082284bafcc8f78573e3915dd728c233c1fa366cedef03b477db0ac67c
bytes.without.task_probe.compose.claude=7997 c568c9082284bafcc8f78573e3915dd728c233c1fa366cedef03b477db0ac67c
bytes.without.task_probe.task.claude=2968 2a47eb7e5f55845d51d53c90c33f4682471e1d372668ea7dab176a4fb2301fbc
bytes.without.objective.compose.O1=296 e54ff3200f40279214eb318de60e6f75da62a6d5fb305f7f7291707fc1a761e7
bytes.without.objective.compose.O4=259 00f12a6ae07ead73cd046e4bfd523ff9406be41e2a9dd403206e33db96fce832
bytes.without.objective.compose.O7=453 0a2a8d04ea6518923e41a46d34769d1309a596cca05cdda86be022f30c085674
bytes.without.objective.compose.O2=281 0bcb511e7eb9ad647b8eb5c63e37799f26e79a638d5806fa69e510612e9d2231
bytes.without.objective.compose.O3=260 03bd34200ff3d0e2e541be2579fe6dc2ac106b47d2d17d61459c9cf106cd745f
bytes.without.objective.compose.O7b=464 bdd4feefeb19dcc8239c41046301e93daa459a7b35508c2f988fafc0856da11e
bytes.without.objective.compose.T5=428 de697d4a469d9c3b181994b40e325652479e6f0899e5e114fd83fb6b65acd236
bytes.with.compose_bench.R-MIN2.nexus=8333 071d393525195cd42c96d8dfab85e0f5e6a785b8c29bf92abd67931b6e261385
bytes.with.task_probe.compose.nexus=8470 e6bbb0a6542ea3a7eee4e959153e5b066afbb9675b574832b0e274c932fcc8d8
bytes.with.task_probe.task.nexus=2934 4b2a4aae71ec5ff42978a6ef6ed7de2dbc7349f9745cd3415a876f1408055113
bytes.with.compose_bench.R-MIN2.claude=8336 c9492b4bc3ef149ed639331dd15b39c88eb033e869a0029e2ee9dadc19711fca
bytes.with.task_probe.compose.claude=8473 5b2a4fc67ca3e3211053b3e7118d730d715810caef09190c14b4007f35e7006d
bytes.with.task_probe.task.claude=2968 2a47eb7e5f55845d51d53c90c33f4682471e1d372668ea7dab176a4fb2301fbc
bytes.with.objective.compose.O1=296 e54ff3200f40279214eb318de60e6f75da62a6d5fb305f7f7291707fc1a761e7
bytes.with.objective.compose.O4=259 00f12a6ae07ead73cd046e4bfd523ff9406be41e2a9dd403206e33db96fce832
bytes.with.objective.compose.O7=453 0a2a8d04ea6518923e41a46d34769d1309a596cca05cdda86be022f30c085674
bytes.with.objective.compose.O2=281 0bcb511e7eb9ad647b8eb5c63e37799f26e79a638d5806fa69e510612e9d2231
bytes.with.objective.compose.O3=260 03bd34200ff3d0e2e541be2579fe6dc2ac106b47d2d17d61459c9cf106cd745f
bytes.with.objective.compose.O7b=464 bdd4feefeb19dcc8239c41046301e93daa459a7b35508c2f988fafc0856da11e
bytes.with.objective.compose.T5=428 de697d4a469d9c3b181994b40e325652479e6f0899e5e114fd83fb6b65acd236
stems.primary.compose.O7b=agent,alone,another,app,bin,build,check,compose,failure,final,first,lint,not,one,output,rail,read,report,right,rubocop,run,script,summarise,summary,test,time,two,wait,write
stems.primary.compose.T5=bin,build,compose,first,not,once,one,output,rail,read,review,right,run,script,see,time,two
stems.control.compose.O1=agent,build,compose,diff,first,not,one,open,patch,read,review,right,run,script,time
stems.control.compose.O2=app,build,compose,file,first,model,name,not,one,read,right,run,script
stems.control.compose.O3=build,compose,first,not,one,read,rest,right,run,script,tell,the rest,use,wait
stems.control.compose.O4=app,bin,build,compose,first,fix,not,offence,one,rail,read,report,right,rubocop,run,script,take,test,wait,whole
stems.control.compose.O7=bash,build,compose,example,first,list,not,one,only,read,right,run,script,source,time,wait
rates_sha256=bc844af13731ed9371281ac090271ad7f98ce5ff43b682e72944ac98121fe35e
replay.with.v13-15=built 260, compared 260, refused alike 0 {}, mismatches 0
replay.with.v16=built 3116, compared 3113, refused alike 3 {"invalid_script" => 2, "unknown_tool_name" => 1}, mismatches 0
replay.with.nul=built 2, compared 0, refused alike 2 {"invalid_script" => 2}, mismatches 0
replay.without.v13-15=built 260, compared 260, refused alike 0 {}, mismatches 0
replay.without.v16=built 3116, compared 3113, refused alike 3 {"invalid_script" => 2, "unknown_tool_name" => 1}, mismatches 0
replay.without.nul=built 2, compared 0, refused alike 2 {"invalid_script" => 2}, mismatches 0
c_inputs=unchanged since 7fdaf8a05f9c4c87ed2309bb905370cdb6fd8ba1
c_inputs.carried.1=c_a=v13 21/21 freed of 28 (expected 28); v14 18/18 freed of 21 (expected 21); v15 17/17 freed of 18 (expected 18); v15 kept line 7 background-suite gpt-6-luna #1; opus/sol freed 10/10 → HOLDS
c_inputs.carried.2=c_b=v13 9 of 51 exact (listed 9); v14 4 of 61 exact (listed 4); v15 5 of 46 exact (listed 5); differences none → HOLDS
c_inputs.carried.3=c_c=control v13+v14 185/186 (≥ 185), v15 74/74 (= 74); readings v13 90, v14 96, v15 74; differs v13 line 135 grep-then-edit kimi-k3 #2: record ["wrong_task_read"] → HOLDS
c_inputs.carried.4=c_d=delivery canonicals 9/9 agree, fixtures 14/14 agree, built 23/23, bound 257, within bound true, distribution {"1" => 17, "2" => 3, "3" => 1, "4" => 1, "7" => 1}; mismatches none → HOLDS
c_inputs.carried.5=c_verdict=HOLDS — C recomputed 2026-09-28 by the voided stage0_c.rb (sha256 ec30643d…) at the readers of 619ad9d1 (42ac90f6, 93459975, 7028cd8c included) over the v13–v15 records as of 83579556, the corpus the voided C read: the four lines are byte-identical to the voided stamp's (launch.txt:23-26). Over main's records today c_b reads MISS only because d8a1c266 re-stamped the nine v15 three-stage-pairing records at lines 82–90 (the break set by task, model and run is unchanged); registered before any draw of this screen.
c_inputs.carried.6=posthoc: C at 283e372a HOLDS modulo deviation 4
sim.E1=n 152, base 81.8 %, zero-effect 69.5 %, at -7.5 6.4 %; single rate 66.2 % / 10.3 %
sim.guard_O1=n 32, base 100.0 %, zero-effect 0.0 %, at -25.0 84.7 %; single rate 0.0 % / 84.7 %
sim.guard_O2=n 24, base 77.8 %, zero-effect 0.8 %, at -25.0 32.8 %; single rate 1.3 % / 34.5 %
sim.guard_O3=n 64, base 98.4 %, zero-effect 0.0 %, at -25.0 99.3 %; single rate 0.0 % / 99.3 %
sim.guard_O4=n 32, base 76.0 %, zero-effect 1.0 %, at -25.0 45.9 %; single rate 1.3 % / 46.4 %
sim.guard_O7=n 32, base 55.2 %, zero-effect 0.5 %, at -25.0 43.8 %; single rate 1.6 % / 45.4 %
sim.E2=n 64, base 9.9 %, zero-effect 6.7 %, at +20.0 96.9 %; single rate 10.6 % / 95.1 %
sim.E4=n 16, base 0.0 %, zero-effect 0.0 %, at +20.0 85.9 %; single rate 0.0 % / 85.9 %
sim.G=n 96, base 91.1 %, zero-effect 88.4 %, at -10.0 9.4 %; single rate 86.9 % / 10.4 %
sim.O3_fall=n 64, base 98.4 %, zero-effect 0.0 %, at -12.5 68.8 %; single rate 0.0 % / 68.2 %
sim.stops=none
smoke.without.openrouter_z-ai_glm-5.3=ok exit=0 draws=1 in=4102 out=7583 cache_read=0 cache_creation=0
smoke.without.anthropic_claude-opus-5-5=ok exit=0 draws=2 in=6124 out=608 cache_read=0 cache_creation=6120
smoke.cache.anthropic_claude-opus-5-5.without=6120 ≥ 0.9 × 6124 ok
smoke.with.openrouter_z-ai_glm-5.3=ok exit=0 draws=1 in=4225 out=5425 cache_read=0 cache_creation=0
smoke.with.anthropic_claude-opus-5-5=ok exit=0 draws=2 in=6244 out=301 cache_read=0 cache_creation=6240
smoke.cache.anthropic_claude-opus-5-5.with=6240 ≥ 0.9 × 6244 ok
smoke_spend_usd=0.158695
smoke_ids=1:O1#1,2:O1#1,2:O1#2,3:O1#1,4:O1#1,4:O1#2
cap.openrouter/z-ai/=8
cap.openrouter/=14
cap.anthropic/=4
cap.openai_api/=4
cap.deepseek/=2
budget.planning_usd=21.2
budget.upper_usd=23
cache_key.without=explicit-reads-rminp/without/<lane>
cache_key.with=explicit-reads-rminp/with/<lane>
watch.spend_stop_usd=25.0
watch.wall_stop_seconds=3600.0
watch.stall_flag_seconds=600.0
watch.stall_stop_seconds=1500.0
watch.storm_share=0.1
watch.storm_min_events=3.0
watch.lost_share=0.05
watch.lost_min_draws=3.0
watch.blind_gap=3.0
watch.take_error_limit=3.0
watch.poll_seconds=15.0
watch.heartbeat_seconds=600.0
watch.kill_grace_seconds=30.0
candidate.feat/explicit-reads=d703d690efd8bec88927e4e1037e649b6e279873
jobs=76
job.1=without compose deepseek/deepseek-flash objectives=O1,O3,O7b,T5 n=4 first=1 dir=without/compose/deepseek_deepseek-flash.1 lane=deepseek row=R-WO style=nexus
job.2=without compose deepseek/deepseek-flash objectives=O1,O3,O7b,T5 n=4 first=5 dir=without/compose/deepseek_deepseek-flash.2 lane=deepseek row=R-WO style=nexus
job.3=without compose deepseek/deepseek-flash objectives=O1,O3,O7b,T5 n=4 first=9 dir=without/compose/deepseek_deepseek-flash.3 lane=deepseek row=R-WO style=nexus
job.4=without compose openrouter/z-ai/glm-5.3-flash objectives=O1,O3,O7b,T5 n=4 first=1 dir=without/compose/openrouter_z-ai_glm-5.3-flash.1 lane=openrouter row=R-WO style=nexus
job.5=without compose openrouter/z-ai/glm-5.3-flash objectives=O1,O3,O7b,T5 n=4 first=5 dir=without/compose/openrouter_z-ai_glm-5.3-flash.2 lane=openrouter row=R-WO style=nexus
job.6=without compose openrouter/z-ai/glm-5.3-flash objectives=O1,O3,O7b,T5 n=4 first=9 dir=without/compose/openrouter_z-ai_glm-5.3-flash.3 lane=openrouter row=R-WO style=nexus
job.7=with compose deepseek/deepseek-flash objectives=O1,O3,O7b,T5 n=4 first=1 dir=with/compose/deepseek_deepseek-flash.1 lane=deepseek row=R-MIN2 style=nexus
job.8=with compose deepseek/deepseek-flash objectives=O1,O3,O7b,T5 n=4 first=5 dir=with/compose/deepseek_deepseek-flash.2 lane=deepseek row=R-MIN2 style=nexus
job.9=with compose deepseek/deepseek-flash objectives=O1,O3,O7b,T5 n=4 first=9 dir=with/compose/deepseek_deepseek-flash.3 lane=deepseek row=R-MIN2 style=nexus
job.10=with compose openrouter/z-ai/glm-5.3-flash objectives=O1,O3,O7b,T5 n=4 first=1 dir=with/compose/openrouter_z-ai_glm-5.3-flash.1 lane=openrouter row=R-MIN2 style=nexus
job.11=with compose openrouter/z-ai/glm-5.3-flash objectives=O1,O3,O7b,T5 n=4 first=5 dir=with/compose/openrouter_z-ai_glm-5.3-flash.2 lane=openrouter row=R-MIN2 style=nexus
job.12=with compose openrouter/z-ai/glm-5.3-flash objectives=O1,O3,O7b,T5 n=4 first=9 dir=with/compose/openrouter_z-ai_glm-5.3-flash.3 lane=openrouter row=R-MIN2 style=nexus
job.13=without compose openrouter/z-ai/glm-5.3 objectives=O1,O4,O7 n=4 first=1 dir=without/compose/openrouter_z-ai_glm-5.3.cell1.1 lane=openrouter row=R-WO style=nexus
job.14=without compose openrouter/z-ai/glm-5.3 objectives=O1,O4,O7 n=4 first=5 dir=without/compose/openrouter_z-ai_glm-5.3.cell1.2 lane=openrouter row=R-WO style=nexus
job.15=without compose openrouter/moonshotai/kimi-k3 objectives=O1,O4,O7 n=4 first=1 dir=without/compose/openrouter_moonshotai_kimi-k3.cell1.1 lane=openrouter row=R-WO style=nexus
job.16=without compose openrouter/moonshotai/kimi-k3 objectives=O1,O4,O7 n=4 first=5 dir=without/compose/openrouter_moonshotai_kimi-k3.cell1.2 lane=openrouter row=R-WO style=nexus
job.17=without compose anthropic/claude-opus-5-5 objectives=O1,O4,O7 n=4 first=1 dir=without/compose/anthropic_claude-opus-5-5.cell1.1 lane=anthropic row=R-WO style=nexus
job.18=without compose anthropic/claude-opus-5-5 objectives=O1,O4,O7 n=4 first=5 dir=without/compose/anthropic_claude-opus-5-5.cell1.2 lane=anthropic row=R-WO style=nexus
job.19=without compose openai_api/gpt-6-sol objectives=O1,O4,O7 n=4 first=1 dir=without/compose/openai_api_gpt-6-sol.cell1.1 lane=openai_api row=R-WO style=nexus
job.20=without compose openai_api/gpt-6-sol objectives=O1,O4,O7 n=4 first=5 dir=without/compose/openai_api_gpt-6-sol.cell1.2 lane=openai_api row=R-WO style=nexus
job.21=without compose openrouter/moonshotai/kimi-k3 objectives=O2 n=4 first=1 dir=without/compose/openrouter_moonshotai_kimi-k3.cell2.1 lane=openrouter row=R-WO style=nexus
job.22=without compose openrouter/moonshotai/kimi-k3 objectives=O2 n=4 first=5 dir=without/compose/openrouter_moonshotai_kimi-k3.cell2.2 lane=openrouter row=R-WO style=nexus
job.23=without compose anthropic/claude-opus-5-5 objectives=O2 n=4 first=1 dir=without/compose/anthropic_claude-opus-5-5.cell2.1 lane=anthropic row=R-WO style=nexus
job.24=without compose anthropic/claude-opus-5-5 objectives=O2 n=4 first=5 dir=without/compose/anthropic_claude-opus-5-5.cell2.2 lane=anthropic row=R-WO style=nexus
job.25=without compose openai_api/gpt-6-sol objectives=O2 n=4 first=1 dir=without/compose/openai_api_gpt-6-sol.cell2.1 lane=openai_api row=R-WO style=nexus
job.26=without compose openai_api/gpt-6-sol objectives=O2 n=4 first=5 dir=without/compose/openai_api_gpt-6-sol.cell2.2 lane=openai_api row=R-WO style=nexus
job.27=without compose openrouter/z-ai/glm-5.3 objectives=O3 n=8 first=1 dir=without/compose/openrouter_z-ai_glm-5.3.cell3.1 lane=openrouter row=R-WO style=nexus
job.28=without compose openrouter/z-ai/glm-5.3 objectives=O3 n=8 first=9 dir=without/compose/openrouter_z-ai_glm-5.3.cell3.2 lane=openrouter row=R-WO style=nexus
job.29=without compose openrouter/z-ai/glm-5.3 objectives=O3 n=8 first=17 dir=without/compose/openrouter_z-ai_glm-5.3.cell3.3 lane=openrouter row=R-WO style=nexus
job.30=without compose openrouter/moonshotai/kimi-k3 objectives=O3 n=8 first=1 dir=without/compose/openrouter_moonshotai_kimi-k3.cell3.1 lane=openrouter row=R-WO style=nexus
job.31=without compose openrouter/moonshotai/kimi-k3 objectives=O3 n=8 first=9 dir=without/compose/openrouter_moonshotai_kimi-k3.cell3.2 lane=openrouter row=R-WO style=nexus
job.32=without compose openrouter/moonshotai/kimi-k3 objectives=O3 n=8 first=17 dir=without/compose/openrouter_moonshotai_kimi-k3.cell3.3 lane=openrouter row=R-WO style=nexus
job.33=without compose anthropic/claude-opus-5-5 objectives=O3 n=4 first=1 dir=without/compose/anthropic_claude-opus-5-5.cell4.1 lane=anthropic row=R-WO style=nexus
job.34=without compose anthropic/claude-opus-5-5 objectives=O3 n=4 first=5 dir=without/compose/anthropic_claude-opus-5-5.cell4.2 lane=anthropic row=R-WO style=nexus
job.35=without compose openai_api/gpt-6-sol objectives=O3 n=4 first=1 dir=without/compose/openai_api_gpt-6-sol.cell4.1 lane=openai_api row=R-WO style=nexus
job.36=without compose openai_api/gpt-6-sol objectives=O3 n=4 first=5 dir=without/compose/openai_api_gpt-6-sol.cell4.2 lane=openai_api row=R-WO style=nexus
job.37=without compose openrouter/z-ai/glm-5.3 objectives=O7b,T5 n=4 first=1 dir=without/compose/openrouter_z-ai_glm-5.3.cell5.1 lane=openrouter row=R-WO style=nexus
job.38=without compose openrouter/z-ai/glm-5.3 objectives=O7b,T5 n=4 first=5 dir=without/compose/openrouter_z-ai_glm-5.3.cell5.2 lane=openrouter row=R-WO style=nexus
job.39=without compose openrouter/moonshotai/kimi-k3 objectives=O7b,T5 n=4 first=1 dir=without/compose/openrouter_moonshotai_kimi-k3.cell5.1 lane=openrouter row=R-WO style=nexus
job.40=without compose openrouter/moonshotai/kimi-k3 objectives=O7b,T5 n=4 first=5 dir=without/compose/openrouter_moonshotai_kimi-k3.cell5.2 lane=openrouter row=R-WO style=nexus
job.41=without compose anthropic/claude-opus-5-5 objectives=O7b,T5 n=4 first=1 dir=without/compose/anthropic_claude-opus-5-5.cell5.1 lane=anthropic row=R-WO style=nexus
job.42=without compose anthropic/claude-opus-5-5 objectives=O7b,T5 n=4 first=5 dir=without/compose/anthropic_claude-opus-5-5.cell5.2 lane=anthropic row=R-WO style=nexus
job.43=without compose openai_api/gpt-6-sol objectives=O7b,T5 n=4 first=1 dir=without/compose/openai_api_gpt-6-sol.cell5.1 lane=openai_api row=R-WO style=nexus
job.44=without compose openai_api/gpt-6-sol objectives=O7b,T5 n=4 first=5 dir=without/compose/openai_api_gpt-6-sol.cell5.2 lane=openai_api row=R-WO style=nexus
job.45=with compose openrouter/z-ai/glm-5.3 objectives=O1,O4,O7 n=4 first=1 dir=with/compose/openrouter_z-ai_glm-5.3.cell1.1 lane=openrouter row=R-MIN2 style=nexus
job.46=with compose openrouter/z-ai/glm-5.3 objectives=O1,O4,O7 n=4 first=5 dir=with/compose/openrouter_z-ai_glm-5.3.cell1.2 lane=openrouter row=R-MIN2 style=nexus
job.47=with compose openrouter/moonshotai/kimi-k3 objectives=O1,O4,O7 n=4 first=1 dir=with/compose/openrouter_moonshotai_kimi-k3.cell1.1 lane=openrouter row=R-MIN2 style=nexus
job.48=with compose openrouter/moonshotai/kimi-k3 objectives=O1,O4,O7 n=4 first=5 dir=with/compose/openrouter_moonshotai_kimi-k3.cell1.2 lane=openrouter row=R-MIN2 style=nexus
job.49=with compose anthropic/claude-opus-5-5 objectives=O1,O4,O7 n=4 first=1 dir=with/compose/anthropic_claude-opus-5-5.cell1.1 lane=anthropic row=R-MIN2 style=nexus
job.50=with compose anthropic/claude-opus-5-5 objectives=O1,O4,O7 n=4 first=5 dir=with/compose/anthropic_claude-opus-5-5.cell1.2 lane=anthropic row=R-MIN2 style=nexus
job.51=with compose openai_api/gpt-6-sol objectives=O1,O4,O7 n=4 first=1 dir=with/compose/openai_api_gpt-6-sol.cell1.1 lane=openai_api row=R-MIN2 style=nexus
job.52=with compose openai_api/gpt-6-sol objectives=O1,O4,O7 n=4 first=5 dir=with/compose/openai_api_gpt-6-sol.cell1.2 lane=openai_api row=R-MIN2 style=nexus
job.53=with compose openrouter/moonshotai/kimi-k3 objectives=O2 n=4 first=1 dir=with/compose/openrouter_moonshotai_kimi-k3.cell2.1 lane=openrouter row=R-MIN2 style=nexus
job.54=with compose openrouter/moonshotai/kimi-k3 objectives=O2 n=4 first=5 dir=with/compose/openrouter_moonshotai_kimi-k3.cell2.2 lane=openrouter row=R-MIN2 style=nexus
job.55=with compose anthropic/claude-opus-5-5 objectives=O2 n=4 first=1 dir=with/compose/anthropic_claude-opus-5-5.cell2.1 lane=anthropic row=R-MIN2 style=nexus
job.56=with compose anthropic/claude-opus-5-5 objectives=O2 n=4 first=5 dir=with/compose/anthropic_claude-opus-5-5.cell2.2 lane=anthropic row=R-MIN2 style=nexus
job.57=with compose openai_api/gpt-6-sol objectives=O2 n=4 first=1 dir=with/compose/openai_api_gpt-6-sol.cell2.1 lane=openai_api row=R-MIN2 style=nexus
job.58=with compose openai_api/gpt-6-sol objectives=O2 n=4 first=5 dir=with/compose/openai_api_gpt-6-sol.cell2.2 lane=openai_api row=R-MIN2 style=nexus
job.59=with compose openrouter/z-ai/glm-5.3 objectives=O3 n=8 first=1 dir=with/compose/openrouter_z-ai_glm-5.3.cell3.1 lane=openrouter row=R-MIN2 style=nexus
job.60=with compose openrouter/z-ai/glm-5.3 objectives=O3 n=8 first=9 dir=with/compose/openrouter_z-ai_glm-5.3.cell3.2 lane=openrouter row=R-MIN2 style=nexus
job.61=with compose openrouter/z-ai/glm-5.3 objectives=O3 n=8 first=17 dir=with/compose/openrouter_z-ai_glm-5.3.cell3.3 lane=openrouter row=R-MIN2 style=nexus
job.62=with compose openrouter/moonshotai/kimi-k3 objectives=O3 n=8 first=1 dir=with/compose/openrouter_moonshotai_kimi-k3.cell3.1 lane=openrouter row=R-MIN2 style=nexus
job.63=with compose openrouter/moonshotai/kimi-k3 objectives=O3 n=8 first=9 dir=with/compose/openrouter_moonshotai_kimi-k3.cell3.2 lane=openrouter row=R-MIN2 style=nexus
job.64=with compose openrouter/moonshotai/kimi-k3 objectives=O3 n=8 first=17 dir=with/compose/openrouter_moonshotai_kimi-k3.cell3.3 lane=openrouter row=R-MIN2 style=nexus
job.65=with compose anthropic/claude-opus-5-5 objectives=O3 n=4 first=1 dir=with/compose/anthropic_claude-opus-5-5.cell4.1 lane=anthropic row=R-MIN2 style=nexus
job.66=with compose anthropic/claude-opus-5-5 objectives=O3 n=4 first=5 dir=with/compose/anthropic_claude-opus-5-5.cell4.2 lane=anthropic row=R-MIN2 style=nexus
job.67=with compose openai_api/gpt-6-sol objectives=O3 n=4 first=1 dir=with/compose/openai_api_gpt-6-sol.cell4.1 lane=openai_api row=R-MIN2 style=nexus
job.68=with compose openai_api/gpt-6-sol objectives=O3 n=4 first=5 dir=with/compose/openai_api_gpt-6-sol.cell4.2 lane=openai_api row=R-MIN2 style=nexus
job.69=with compose openrouter/z-ai/glm-5.3 objectives=O7b,T5 n=4 first=1 dir=with/compose/openrouter_z-ai_glm-5.3.cell5.1 lane=openrouter row=R-MIN2 style=nexus
job.70=with compose openrouter/z-ai/glm-5.3 objectives=O7b,T5 n=4 first=5 dir=with/compose/openrouter_z-ai_glm-5.3.cell5.2 lane=openrouter row=R-MIN2 style=nexus
job.71=with compose openrouter/moonshotai/kimi-k3 objectives=O7b,T5 n=4 first=1 dir=with/compose/openrouter_moonshotai_kimi-k3.cell5.1 lane=openrouter row=R-MIN2 style=nexus
job.72=with compose openrouter/moonshotai/kimi-k3 objectives=O7b,T5 n=4 first=5 dir=with/compose/openrouter_moonshotai_kimi-k3.cell5.2 lane=openrouter row=R-MIN2 style=nexus
job.73=with compose anthropic/claude-opus-5-5 objectives=O7b,T5 n=4 first=1 dir=with/compose/anthropic_claude-opus-5-5.cell5.1 lane=anthropic row=R-MIN2 style=nexus
job.74=with compose anthropic/claude-opus-5-5 objectives=O7b,T5 n=4 first=5 dir=with/compose/anthropic_claude-opus-5-5.cell5.2 lane=anthropic row=R-MIN2 style=nexus
job.75=with compose openai_api/gpt-6-sol objectives=O7b,T5 n=4 first=1 dir=with/compose/openai_api_gpt-6-sol.cell5.1 lane=openai_api row=R-MIN2 style=nexus
job.76=with compose openai_api/gpt-6-sol objectives=O7b,T5 n=4 first=5 dir=with/compose/openai_api_gpt-6-sol.cell5.2 lane=openai_api row=R-MIN2 style=nexus
launched_at=2026-09-27T21:29:26Z
```

## Verdict: LAND

E1, E2, E3, E4 and G hold and no guard fires: the explicit-reads kernel lands with R-MIN2 (8333 bytes, sha256 071d393525195cd42c96d8dfab85e0f5e6a785b8c29bf92abd67931b6e261385) as the shipped compose text.

## Clauses

- E1 with: 120/152 (78.9 %) against without 119/152 (78.3 %); Δ +0.7 pts, lower -5.4, upper +6.7 at z 1.2816 (lower ≥ -7.5) → **HOLDS**
- guard O1 without: 32/32 (100.0 %) against with 29/32 (90.6 %); Δ +9.4 pts, lower -5.2, upper +26.4 at z 2.1893 (fires when the fall's lower bound > 0) → **does not hold**
- guard O2 without: 20/24 (83.3 %) against with 20/24 (83.3 %); Δ +0.0 pts, lower -24.2, upper +24.2 at z 2.1893 (fires when the fall's lower bound > 0) → **does not hold**
- guard O3 without: 56/64 (87.5 %) against with 53/64 (82.8 %); Δ +4.7 pts, lower -9.5, upper +18.8 at z 2.1893 (fires when the fall's lower bound > 0) → **does not hold**
- guard O4 without: 18/32 (56.3 %) against with 25/32 (78.1 %); Δ -21.9 pts, lower -44.0, upper +3.7 at z 2.1893 (fires when the fall's lower bound > 0) → **does not hold**
- guard O7 without: 18/32 (56.3 %) against with 18/32 (56.3 %); Δ +0.0 pts, lower -25.4, upper +25.4 at z 2.1893 (fires when the fall's lower bound > 0) → **does not hold**
- E2 with: 55/64 (85.9 %) against without 8/64 (12.5 %); Δ +73.4 pts, lower +64.4, upper +79.8 at z 1.2816 (lower > 0) → **HOLDS**
- E3 with: 2/64 (3.1 %) against without 0/64 (0.0 %); Δ +3.1 pts, lower +0.0, upper +7.3 at z 1.2816 (over_read_named in at most 2 of the with arm's draws) → **HOLDS**
- E4 with: 16/16 (100.0 %) against without 0/16 (0.0 %); Δ +100.0 pts, lower +86.8, upper +100.0 at z 1.2816 (lower > 0) → **HOLDS**
- G with: 91/96 (94.8 %) against without 83/96 (86.5 %); Δ +8.3 pts, lower +3.0, upper +13.9 at z 1.2816 (lower ≥ -10.0) → **HOLDS**

## Reads (printed, never deciding)

- O3 glm-5.3: right″ with 16/24, without 18/24; tagged (member_not_a_step) 0, 0; a race with no reader 6, 0
- O3 kimi-k3: right″ with 21/24, without 22/24; tagged (member_not_a_step) 0, 2; a race with no reader 3, 0
- O3 claude-opus-5-5: right″ with 8/8, without 8/8; tagged (member_not_a_step) 0, 0; a race with no reader 0, 0
- O3 gpt-6-sol: right″ with 8/8, without 8/8; tagged (member_not_a_step) 0, 0; a race with no reader 0, 0
- O2 kimi-k3: right″ with 6/8, without 6/8
- O2 claude-opus-5-5: right″ with 8/8, without 8/8
- O2 gpt-6-sol: right″ with 6/8, without 6/8
- E2 futility: the rise's upper bound is +79.8 points, not under +10
- opaque plans: with 50 of 344, without 56 of 344
- lineage: R-EX (8470 bytes, sha256 e6bbb0a6542ea3a7eee4e959153e5b066afbb9675b574832b0e274c932fcc8d8) → R-MIN (8206 bytes, sha256 bed2c651b28ec1cd1775e07ad67b5a22624db650e58bc4e17ad64ca8e35149db) → R-MIN2 (8333 bytes, sha256 071d393525195cd42c96d8dfab85e0f5e6a785b8c29bf92abd67931b6e261385); the base R-WO (7994 bytes, sha256 1e69b087f7b773c5a7f1385970a164f65585216ed22b6a9388e136a986499ad6)
- the screen tells a recovered O3 from an R-MIN-like one 3.7 : 1; the O3 guard at 64 an arm vetoes R-MIN's own fall about two times in three (the voided batch's own veto was a 68 % event) and vetoes the recut's realistic ceiling, R-EX-level O3, 31 % of the time; the recut reaches the tagged class alone, 3 of the 9 strong-tier O3 misses
- kimi-k3's O2 fall under R-MIN (18 → 9 of 24) is read per model and enters E1 and the O2 guard, but the O2 guard at 24 an arm sees it 5.9 % of the time: this screen cannot re-decide it
- a neutral candidate lands 58 % of the time, the price of size the rule accepts; E2 and E4 pass by the mechanism (R-MIN 187/192 and 48/48 in the voided batch)
- at zero effect the whole conjunction never lands: E4 never passes a zero-effect change

## Lost draws and retries per (model, arm)

| model | arm | draws | lost | retries |
|---|---|---|---|---|
| anthropic/claude-opus-5-5 | with | 56 | 0 | 0 |
| anthropic/claude-opus-5-5 | without | 56 | 0 | 0 |
| deepseek/deepseek-flash | with | 48 | 0 | 0 |
| deepseek/deepseek-flash | without | 48 | 0 | 0 |
| openai_api/gpt-6-sol | with | 56 | 0 | 0 |
| openai_api/gpt-6-sol | without | 56 | 0 | 0 |
| openrouter/moonshotai/kimi-k3 | with | 72 | 0 | 0 |
| openrouter/moonshotai/kimi-k3 | without | 72 | 0 | 0 |
| openrouter/z-ai/glm-5.3 | with | 64 | 0 | 0 |
| openrouter/z-ai/glm-5.3 | without | 64 | 0 | 0 |
| openrouter/z-ai/glm-5.3-flash | with | 48 | 0 | 0 |
| openrouter/z-ai/glm-5.3-flash | without | 48 | 0 | 0 |

## Cost per (model, arm)

| model | arm | draws | calls | input | output | cache read | cache write | $ |
|---|---|---|---|---|---|---|---|---|
| anthropic/claude-opus-5-5 | with | 56 | 56 | 351040 | 24578 | 349122 | 1694 | $0.5708 |
| anthropic/claude-opus-5-5 | without | 56 | 56 | 344320 | 32825 | 342670 | 1426 | $0.7331 |
| deepseek/deepseek-flash | with | 48 | 50 | 227208 | 59659 | 213632 | 0 | $0.0769 |
| deepseek/deepseek-flash | without | 48 | 54 | 252226 | 99217 | 243676 | 0 | $0.1231 |
| openai_api/gpt-6-sol | with | 56 | 59 | 219379 | 25436 | 214024 | 5178 | $0.3105 |
| openai_api/gpt-6-sol | without | 56 | 60 | 217272 | 37000 | 211267 | 5825 | $0.4272 |
| openrouter/moonshotai/kimi-k3 | with | 72 | 73 | 301872 | 212524 | 288803 | 0 | $2.0375 |
| openrouter/moonshotai/kimi-k3 | without | 72 | 75 | 302458 | 241669 | 268310 | 0 | $2.5577 |
| openrouter/z-ai/glm-5.3 | with | 64 | 67 | 285987 | 598035 | 282304 | 0 | $2.2962 |
| openrouter/z-ai/glm-5.3 | without | 64 | 65 | 268394 | 728090 | 265920 | 0 | $2.778 |
| openrouter/z-ai/glm-5.3-flash | with | 48 | 51 | 218007 | 140365 | 69632 | 0 | $0.0945 |
| openrouter/z-ai/glm-5.3-flash | without | 48 | 51 | 212460 | 263582 | 55296 | 0 | $0.157 |

## Machine lines (the launch reads them)

```text
verdict=LAND
relaunch=none
definition_sha256=27bc183b90f191fa4b3dcf1f12a84c33a1b7d6eefb765ae42be13f20d1a70548
stamp_sha256=a0e6a61a24a2833e56883bae355d4138eace77a8aa17ddfec2ae57281ad4843b
```
