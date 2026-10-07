# Use a background result in a later requested turn without repeating the work.

The first turn must start a task and finish while that branch is running. The kernel must mail its result, and the second requested turn must name `test_subtracts` from that history without rerunning the suite. Passive wake is allowed here because the instruction asks for the result in the later requested turn; automatic receipt wake is recorded separately.

The runnable instruction, expected predicates and verifier beside this file define the current evaluation. Provider failures, incomplete execution and incorrect model conduct are reported separately.

## Reading a red

Inspect the recorded request, task graph and verifier output together. A provider or harness failure is a lane bug, not model conduct. A completed run that chooses the wrong tools or produces the wrong result is model conduct. A kernel finding requires a trace showing that an accepted operation violated its documented execution or delivery contract.
