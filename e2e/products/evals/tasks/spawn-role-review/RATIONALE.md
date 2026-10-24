# spawn-role-review

**Measures.** A temporary child selected through the built-in reviewer role,
with `wait: true`, followed by the parent's answer using its returned line number.
Role selection captures execution configuration without selecting another
persistent Main Agent or Bot identity.

**Fixture.** `lib/calc.rb` contains `sub` implemented as `a + b` on line 3.
The ordinary rho installation already publishes the reviewer role. One daemon
and the `plain` driver are sufficient; no second identity or home is provisioned.
The role follows the spawning round's model. The corresponding paid diagnostic
is `E2E_LIVE=1 E2E_SPAWN_VARIANTS=role rake live_spawn`.

**Dimensions.** Reach requires a `spawn` row whose canonical
`tool_input.declaration` is `reviewer`. The model sees the role parameter declared
by its tool style; the kernel resolves that alias before storing the row.
Success requires `wait: true`, a completed spawn, and the final answer naming
line 3. Recorded facts are `role`, `waited`, and `line_named`. No file verification
is needed because the task requests a review, not a change.

## Reading a red

- **lane bug** — the built-in reviewer is absent, configuration cannot be
  captured, or the deadline expires before the paired result settles.
- **model conduct** — it reviews the file itself, selects another role, does not
  wait, or fails to relay the line number into its answer.
- **kernel finding** — the completed waited spawn's result is absent from the
  continuation's sealed request, or is also delivered as separate child mail.
  Inspect the request and events before attributing a missing number to delivery.
