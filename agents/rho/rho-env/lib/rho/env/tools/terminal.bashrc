# The task owns ordinary shell jobs as well as the shell. Disowned jobs and
# programs that deliberately create a new session are outside that ownership.
trap 'for job in $(jobs -pr) $(jobs -ps); do kill -KILL -- "-$job" 2>/dev/null || kill -KILL "$job" 2>/dev/null; done' EXIT
