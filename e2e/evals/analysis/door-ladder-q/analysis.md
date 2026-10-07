# door-ladder-q — analysis

## Provenance (the stamp is the header)

```text
mode=real
screen=door-ladder-q
definition_sha256=338ddc13586175ab096166991324a292eb65c3c03a64ce4d9cc9cf707cb87df6
design=docs/plans/2026-09-27-door-screen-design.md Registered
design_section_sha256=d61e7948a20270ad536efddd99fae9311a85fe560002124c244100936e6b0f79
corpus.v13-15=fdb1ff5f5678468d7f2a386622def728df16603eabfafbb131b3e5b1de2b9848
corpus.v16=ae956c6bb3caef1965f44a3c51f3ead241b83678f5b947b5da8bbfebfcc2359c
corpus.nul=fafdaf31a6bce7238ece605a9ab7f4df3a34f65f35428b2f946e206f34766180
corpus.declarations=7cee0cade3a9f598bc4d1992a052ebdb5e6b4f282cd8828e3c5e63d4d8b172ad
corpus.door=620043fe91beba3b3a83d7524ebae7c339fdf88198844b8d3f0b2034210b73ef
head.with=a67109bd6cdf609646b5349630cee6093c761b54
head.without=4e81375ec715c0f8f63b1764c3cae048a31d24c0
tree.with.root=/Users/jasl/Workspaces/cybros-ai.alt2-dlq
tree.with.state=a67109bd6cdf609646b5349630cee6093c761b54 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 766f1137c9798b39449afec96ff9cf35ce6d75155edfa074f4ddc6455ba3c064
tree.without.root=/Users/jasl/Workspaces/cybros-ai.alt2-dl
tree.without.state=4e81375ec715c0f8f63b1764c3cae048a31d24c0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 766f1137c9798b39449afec96ff9cf35ce6d75155edfa074f4ddc6455ba3c064
base_ref=feat/door-ladder
base=4e81375ec715c0f8f63b1764c3cae048a31d24c0
base_ref_head=4e81375ec715c0f8f63b1764c3cae048a31d24c0
transport_diff=none
allowlist_diff=contracts/nexus/v1/profiles.json e2e/support/compose_bench/rows.rb e2e/test/compose_bench_rows_harness_test.rb nexus/lib/nexus/tool_registry/graph.rb
load_1min=8.37
load_ceiling=16.0
bytes.without.compose_bench.R-LADDER.nexus=9655 c3536d6dd0ace18ecb7c57b30cf0f21a3916ba4507cf18603ed604b9a9bb6794
bytes.without.task_probe.compose.nexus=9655 c3536d6dd0ace18ecb7c57b30cf0f21a3916ba4507cf18603ed604b9a9bb6794
bytes.without.task_probe.task.nexus=3056 65fcdb0162ca549bfb91c09907897a4a0d5cf635015b70f4e60399ff5d6b76aa
bytes.without.compose_bench.R-LADDER.claude=9661 b2cebf6e150f208add2bc2fd8685ba7a47ac641683e294755fc3a4e1b382df65
bytes.without.task_probe.compose.claude=9661 b2cebf6e150f208add2bc2fd8685ba7a47ac641683e294755fc3a4e1b382df65
bytes.without.task_probe.task.claude=3090 1eb038a12029ef2706e79adf2365dacf0fb2b105982e0ccff0af8964feedee64
bytes.without.objective.task.D1P=740 f4f668aa907d39b3fa27905c6df2841aace873c7b20eb21f64d8a02ff49c46b6
bytes.without.fixture.task.D1P=899 2ed7b02c591c17ee4cc8e44dc1c0fb049c46e4803b3efa8b008ceaccd18e4e09
bytes.without.objective.task.D2P=325 331ea90f13233b716b6262d9308a25c41ac1435caf897583de2998b6b52643de
bytes.without.fixture.task.D2P=761 ff38be0205aa3ae2ceeec7da4afbef80bb204ced8acefb1a0f2787a292f948de
bytes.without.objective.task.D4P=246 c938288dbe07721cf0297443cd6728808b8d5010716e51527e5cbc11c0133cb1
bytes.without.fixture.task.D4P=1508 9ac0b167d49da98d66f00ffa0febe1dbd93c5064ef3b9ea4dbcc7800fe98772e
bytes.without.objective.task.D3P=292 b6bce9879e23d9d987e9911c9e2b3949aecc443c867a29bdb1c27de2b3b92b84
bytes.without.fixture.task.D3P=978 e00f76385794ae4372fbdc2f9ddca942aee99e6f5514dcd13063680f70c48ca9
bytes.without.objective.task.T5=77 aed630d25f9d07b7c5aa736f540a4155198c82c6c3a918b75a12a47b4368902e
bytes.without.fixture.task.T5=2 44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
bytes.without.objective.task.G0=107 389e7f214746a981d5cdef0db46aabe52d9c7d4ce21590f596b6278a37968616
bytes.without.fixture.task.G0=2 44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
bytes.with.compose_bench.R-LADDER-Q-alt.nexus=9669 6966a97ea72913a7909d2bcf861d2bc0cc2d98c22499c65d15f9ef8ef0d10cff
bytes.with.task_probe.compose.nexus=9669 6966a97ea72913a7909d2bcf861d2bc0cc2d98c22499c65d15f9ef8ef0d10cff
bytes.with.task_probe.task.nexus=3056 65fcdb0162ca549bfb91c09907897a4a0d5cf635015b70f4e60399ff5d6b76aa
bytes.with.compose_bench.R-LADDER-Q-alt.claude=9674 80752de0992543fa4bd7325945fae72c86282454c1905d2907a680926c25f921
bytes.with.task_probe.compose.claude=9674 80752de0992543fa4bd7325945fae72c86282454c1905d2907a680926c25f921
bytes.with.task_probe.task.claude=3090 1eb038a12029ef2706e79adf2365dacf0fb2b105982e0ccff0af8964feedee64
bytes.with.objective.task.D1P=740 f4f668aa907d39b3fa27905c6df2841aace873c7b20eb21f64d8a02ff49c46b6
bytes.with.fixture.task.D1P=899 2ed7b02c591c17ee4cc8e44dc1c0fb049c46e4803b3efa8b008ceaccd18e4e09
bytes.with.objective.task.D2P=325 331ea90f13233b716b6262d9308a25c41ac1435caf897583de2998b6b52643de
bytes.with.fixture.task.D2P=761 ff38be0205aa3ae2ceeec7da4afbef80bb204ced8acefb1a0f2787a292f948de
bytes.with.objective.task.D4P=246 c938288dbe07721cf0297443cd6728808b8d5010716e51527e5cbc11c0133cb1
bytes.with.fixture.task.D4P=1508 9ac0b167d49da98d66f00ffa0febe1dbd93c5064ef3b9ea4dbcc7800fe98772e
bytes.with.objective.task.D3P=292 b6bce9879e23d9d987e9911c9e2b3949aecc443c867a29bdb1c27de2b3b92b84
bytes.with.fixture.task.D3P=978 e00f76385794ae4372fbdc2f9ddca942aee99e6f5514dcd13063680f70c48ca9
bytes.with.objective.task.T5=77 aed630d25f9d07b7c5aa736f540a4155198c82c6c3a918b75a12a47b4368902e
bytes.with.fixture.task.T5=2 44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
bytes.with.objective.task.G0=107 389e7f214746a981d5cdef0db46aabe52d9c7d4ce21590f596b6278a37968616
bytes.with.fixture.task.G0=2 44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
stems.primary.task.D1P=list,not,one,per
stems.primary.task.D2P=file,not
stems.primary.task.D4P=not
stems.primary.task.D3P=one
stems.control.task.T5=none
stems.control.task.G0=call,read
rates_sha256=439fd74b38b51a6cca96d8a2c4d4767ba314f73d97494835e1221dc8b4e2ce31
replay.with.v13-15=built 260, compared 260, refused alike 0 {}, mismatches 0
replay.with.v16=built 3116, compared 3113, refused alike 3 {"invalid_script" => 2, "unknown_tool_name" => 1}, mismatches 0
replay.with.nul=built 2, compared 0, refused alike 2 {"invalid_script" => 2}, mismatches 0
replay.without.v13-15=built 260, compared 260, refused alike 0 {}, mismatches 0
replay.without.v16=built 3116, compared 3113, refused alike 3 {"invalid_script" => 2, "unknown_tool_name" => 1}, mismatches 0
replay.without.nul=built 2, compared 0, refused alike 2 {"invalid_script" => 2}, mismatches 0
counterfactual.v13-15=scripts 275, builds 260 in both trees; listed refusals old → new: group_reference → group_reference 2
counterfactual.v13-15.door_kind=compose_steps 114, compose_flat 74, compose_opaque 61, compose_refused 15, compose_tools 9, compose_one 2
counterfactual.v16=scripts 3265, builds 3116 in both trees; listed refusals old → new: group_reference → group_reference 59
counterfactual.v16.door_kind=compose_steps 1770, compose_flat 778, compose_opaque 548, compose_refused 152, compose_tools 17
door_reader=the register holds: 363 records; compose_flat 8, compose_one 2, compose_opaque 5, compose_refused 2, compose_steps 6, compose_tools 3, none 60, plain 90, scout 8, spawn 4, start_process 21, task_fan 70, task_one 84; scored at round 1: 181, round 2: 135, round 3: 39, scout: 8
c_inputs=not registered
sim.Q_D3=n 40, base 20.0 %, zero-effect 10.2 %, at +30.0 94.6 %; single rate 10.2 % / 94.6 %
sim.E1_guard=n 120, base 66.7 %, zero-effect 0.0 %, at -20.0 64.9 %; single rate 0.2 % / 63.2 %
sim.H1=n 80, base 1.0 %, zero-effect 0.4 %, at +10.0 96.5 %; single rate 0.4 % / 96.5 %
sim.stops=none
smoke.without.openrouter_z-ai_glm-5.3=ok exit=0 draws=1 in=10053 out=1125 cache_read=9856 cache_creation=0
smoke.without.openrouter_moonshotai_kimi-k3=ok exit=0 draws=1 in=9511 out=909 cache_read=0 cache_creation=0
smoke.without.anthropic_claude-opus-5-5=ok exit=0 draws=2 in=14716 out=811 cache_read=0 cache_creation=14712
smoke.cache.anthropic_claude-opus-5-5.without=14712 ≥ 0.9 × 14716 ok
smoke.without.openai_api_gpt-6-sol=ok exit=0 draws=1 in=8484 out=115 cache_read=0 cache_creation=8481
smoke.with.openrouter_z-ai_glm-5.3=ok exit=0 draws=1 in=10060 out=1705 cache_read=2048 cache_creation=0
smoke.with.openrouter_moonshotai_kimi-k3=ok exit=0 draws=1 in=9520 out=701 cache_read=0 cache_creation=0
smoke.with.anthropic_claude-opus-5-5=ok exit=0 draws=2 in=14723 out=438 cache_read=0 cache_creation=14719
smoke.cache.anthropic_claude-opus-5-5.with=14719 ≥ 0.9 × 14723 ok
smoke.with.openai_api_gpt-6-sol=ok exit=0 draws=1 in=8493 out=141 cache_read=0 cache_creation=8490
smoke_spend_usd=0.363659
smoke_ids=1:D3P#1,2:D3P#1,3:D3P#1,3:D3P#2,4:D3P#1,5:D3P#1,6:D3P#1,7:D3P#1,7:D3P#2,8:D3P#1
cap.openrouter/z-ai/=8
cap.openrouter/=14
cap.anthropic/=4
cap.openai_api/=4
cap.deepseek/=2
budget.planning_usd=13.5
budget.upper_usd=25
cache_key.without=door-ladder-q/without/<lane>
cache_key.with=door-ladder-q/with/<lane>
watch.spend_stop_usd=30.0
watch.wall_stop_seconds=4500.0
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
candidate.feat/door-ladder-q=a67109bd6cdf609646b5349630cee6093c761b54
jobs=12
job.1=without task openrouter/z-ai/glm-5.3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=1 dir=without/task/openrouter_z-ai_glm-5.3.1 lane=openrouter row=- style=nexus
job.2=without task openrouter/z-ai/glm-5.3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=6 dir=without/task/openrouter_z-ai_glm-5.3.2 lane=openrouter row=- style=nexus
job.3=without task openrouter/moonshotai/kimi-k3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=1 dir=without/task/openrouter_moonshotai_kimi-k3.1 lane=openrouter row=- style=nexus
job.4=without task openrouter/moonshotai/kimi-k3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=6 dir=without/task/openrouter_moonshotai_kimi-k3.2 lane=openrouter row=- style=nexus
job.5=without task anthropic/claude-opus-5-5 objectives=D1P,D2P,D4P,D3P,T5,G0 n=10 first=1 dir=without/task/anthropic_claude-opus-5-5 lane=anthropic row=- style=nexus
job.6=without task openai_api/gpt-6-sol objectives=D1P,D2P,D4P,D3P,T5,G0 n=10 first=1 dir=without/task/openai_api_gpt-6-sol lane=openai_api row=- style=nexus
job.7=with task openrouter/z-ai/glm-5.3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=1 dir=with/task/openrouter_z-ai_glm-5.3.1 lane=openrouter row=- style=nexus
job.8=with task openrouter/z-ai/glm-5.3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=6 dir=with/task/openrouter_z-ai_glm-5.3.2 lane=openrouter row=- style=nexus
job.9=with task openrouter/moonshotai/kimi-k3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=1 dir=with/task/openrouter_moonshotai_kimi-k3.1 lane=openrouter row=- style=nexus
job.10=with task openrouter/moonshotai/kimi-k3 objectives=D1P,D2P,D4P,D3P,T5,G0 n=5 first=6 dir=with/task/openrouter_moonshotai_kimi-k3.2 lane=openrouter row=- style=nexus
job.11=with task anthropic/claude-opus-5-5 objectives=D1P,D2P,D4P,D3P,T5,G0 n=10 first=1 dir=with/task/anthropic_claude-opus-5-5 lane=anthropic row=- style=nexus
job.12=with task openai_api/gpt-6-sol objectives=D1P,D2P,D4P,D3P,T5,G0 n=10 first=1 dir=with/task/openai_api_gpt-6-sol lane=openai_api row=- style=nexus
launched_at=2026-09-28T14:31:10Z
```

## Verdict: SHIP-LADDER

Q-D3 does not hold: R-LADDER ships as the one landing, then v17 on the owner's cadence.

## Clauses

- Q-D3 with: 0/40 (0.0 %) against without 8/40 (20.0 %); Δ -20.0 pts, lower -29.2, upper -12.1 at z 1.2816 (lower > 0) → **does not hold**
- E1 guard without: 79/120 (65.8 %) against with 83/120 (69.2 %); Δ -3.3 pts, lower -11.0, upper +4.4 at z 1.2816 (fires when the fall's lower > +10) → **does not hold**
- H1 with: 0/80 (0.0 %) against without 0/80 (0.0 %); Δ +0.0 pts, lower -2.0, upper +2.0 at z 1.2816 (fires when with − base ≥ 4 and with ≥ 4) → **does not hold**

## Reads (printed, never deciding)

- Q-D3 glm-5.3: with 0/10, without 0/10; task fans of five 10, 10
- Q-D3 kimi-k3: with 0/10, without 0/10; task fans of five 10, 10
- Q-D3 claude-opus-5-5: with 0/10, without 8/10; task fans of five 10, 2
- Q-D3 gpt-6-sol: with 0/10, without 0/10; task fans of five 4, 0
- right door D1P: with 22/40, without 18/40
- right door D2P: with 35/40, without 34/40
- right door D4P: with 26/40, without 27/40
- right door D3P: with 34/40, without 30/40
- D3P door_kind with: task_fan 34, task_one 6
- D3P door_kind without: task_fan 22, task_one 10, compose_steps 8
- D3P cost per draw with: $0.0114 over 40 draws (reported charges)
- D3P cost per draw without: $0.0069 over 40 draws (reported charges)

## Lost draws and retries per (model, arm)

| model | arm | draws | lost | retries |
|---|---|---|---|---|
| anthropic/claude-opus-5-5 | with | 60 | 0 | 0 |
| anthropic/claude-opus-5-5 | without | 60 | 0 | 0 |
| openai_api/gpt-6-sol | with | 60 | 0 | 0 |
| openai_api/gpt-6-sol | without | 60 | 0 | 0 |
| openrouter/moonshotai/kimi-k3 | with | 60 | 0 | 0 |
| openrouter/moonshotai/kimi-k3 | without | 60 | 0 | 0 |
| openrouter/z-ai/glm-5.3 | with | 60 | 0 | 0 |
| openrouter/z-ai/glm-5.3 | without | 60 | 0 | 0 |

## Cost per (model, arm)

| model | arm | draws | calls | input | output | cache read | cache write | $ |
|---|---|---|---|---|---|---|---|---|
| anthropic/claude-opus-5-5 | with | 60 | 60 | 883380 | 28648 | 882200 | 940 | $0.7551 |
| anthropic/claude-opus-5-5 | without | 60 | 60 | 882960 | 23925 | 881780 | 940 | $0.6605 |
| openai_api/gpt-6-sol | with | 60 | 61 | 518314 | 17698 | 517410 | 721 | $0.2826 |
| openai_api/gpt-6-sol | without | 60 | 60 | 508840 | 12567 | 508270 | 390 | $0.2287 |
| openrouter/moonshotai/kimi-k3 | with | 60 | 60 | 571037 | 75063 | 352934 | 0 | $1.8861 |
| openrouter/moonshotai/kimi-k3 | without | 60 | 61 | 580131 | 71340 | 426656 | 0 | $1.6585 |
| openrouter/z-ai/glm-5.3 | with | 60 | 62 | 623919 | 247701 | 600064 | 0 | $1.2076 |
| openrouter/z-ai/glm-5.3 | without | 60 | 62 | 623525 | 218218 | 588160 | 0 | $1.0119 |

## Machine lines (the launch reads them)

```text
verdict=SHIP-LADDER
relaunch=none
definition_sha256=338ddc13586175ab096166991324a292eb65c3c03a64ce4d9cc9cf707cb87df6
stamp_sha256=a8a498eb3b18282b771873b1bed30eda6fdbfa5dac2c43f0cbdae1b00a1f6674
```
