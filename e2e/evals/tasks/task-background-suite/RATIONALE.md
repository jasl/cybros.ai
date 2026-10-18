# Run a suite in the background while lint runs directly.

Reach requires a `task` call. Success requires exactly one background task naming the suite, a direct bash invocation of RuboCop, and no `start_process` call. The fixture supplies the suite and lint commands; execution traces determine whether the model delegated, waited, or ran the commands itself.

The runnable instruction, expected predicates and verifier beside this file define the current evaluation. Provider failures, incomplete execution and incorrect model conduct are reported separately.

## Reading a red

Inspect the recorded request, task graph and verifier output together. A provider or harness failure is a lane bug, not model conduct. A completed run that chooses the wrong tools or produces the wrong result is model conduct. A kernel finding requires a trace showing that an accepted operation violated its documented execution or delivery contract.
