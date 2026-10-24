# THE SUITE IS THE VERDICT, with the shipped test restored first (a model
# that edited the specification is judged against the specification).
lambda do |project, _seed|
  output, status = project.run("ruby -Ilib -Itest test/cart_test.rb")
  { "pass" => status.success?, "output" => output.lines.last(6).join }
end
