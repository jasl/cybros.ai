# Read three small files with parallel tool calls and answer the exact claim.

Reach requires at least two tool calls in the first round. Success requires coverage of all three files with no task delegation. The claim reader accepts only an answer identifying `charlie.rb` as defining `run`; naming the other files beside their own methods is allowed. Hidden file coverage and answer conduct are separate checks.

The runnable instruction, expected predicates and verifier beside this file define the current evaluation. Provider failures, incomplete execution and incorrect model conduct are reported separately.

## Reading a red

Inspect the recorded request, task graph and verifier output together. A provider or harness failure is a lane bug, not model conduct. A completed run that chooses the wrong tools or produces the wrong result is model conduct. A kernel finding requires a trace showing that an accepted operation violated its documented execution or delivery contract.
