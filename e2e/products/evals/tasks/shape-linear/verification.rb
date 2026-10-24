# The verdict is the program's, never the transcript's: `ruby fizzbuzz.rb`
# prints the fifteen lines, and nothing else.
expected = (1..15).map do |n|
  if (n % 15).zero? then "FizzBuzz"
  elsif (n % 3).zero? then "Fizz"
  elsif (n % 5).zero? then "Buzz"
  else n.to_s
  end
end.join("\n")

lambda do |project, _seed|
  return { "pass" => false, "output" => "fizzbuzz.rb was never written" } unless File.file?(File.join(project.root, "fizzbuzz.rb"))

  output, status = project.run("ruby fizzbuzz.rb")
  { "pass" => status.success? && output.strip == expected, "output" => output[0, 400] }
end
