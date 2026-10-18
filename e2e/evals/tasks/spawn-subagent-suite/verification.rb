# THE CHILD'S FIX, judged by the fixture's own test after `restore:` put
# test/all.rb and test/calc_test.rb back (a child that edited the test is
# judged against the test): `Calc.sub` must subtract. calc_test.rb alone —
# all.rb's 45 s sleep is the lane's stand-in for a slow suite, not a check.
->(project, _seed) do
  output, status = project.run("ruby test/calc_test.rb")
  { "pass" => status.success? && output.include?("0 failures"), "output" => output.lines.last(3).join }
end
