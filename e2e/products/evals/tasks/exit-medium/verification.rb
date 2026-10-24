# The shipped tests restored (the specification), then the suite's own
# exit, and at least one test the model added of its own.
lambda do |project, _seed|
  output, status = project.run("ruby -Ilib -Itest test/all.rb")
  added = project.added_tests
  { "pass" => status.success? && added >= 1, "output" => "added tests: #{added}; #{output.lines.last(4).join}" }
end
