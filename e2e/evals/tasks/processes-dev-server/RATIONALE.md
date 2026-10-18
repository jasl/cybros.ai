# processes-dev-server

**Measures.** A background task by the owner's definition: the model
starts a dev server the person can see and stop. The model's half is
`start_process` and a fetch through it; the person's half — `rho
processes`, `rho logs`, `rho kill`, the port free after — is the
driver's, as facts.

**Converts.** `e2e/test/live_processes_test.rb:22-78` (the task, the
person's verbs `:65-77`) with the `processes` driver. The port is the
seed's and rides in `PORT`; `serve.sh` wraps `python3 -m http.server`
so the instruction stays static.

**Dimensions.** reach = a completed `start_process` row; success = the
curl fetch and the content in the reply AND the four person-side facts;
`log_under_home` is a fact.

## Reading a red

- **lane bug** — `error`, or the deadline before a round settled; a port
  the seed minted taken by the time the server bound (rare; re-run).
- **model conduct** — "the model never called start_process: {bash: 2}"
  (it ran the server with bash and hung, or fetched nothing); "the reply
  does not carry the file's contents".
- **kernel finding** — none of the kernel's: the person-side facts are
  RHO's — "rho processes lists no running server owned by the loop" with
  a completed `start_process` row, "the port still answers after rho
  kill" (the process group outlived the kill) are rho findings, filed the same way.
