# The rename landed in the one file that defined the method, and the two
# that did not are untouched.
lambda do |project, _seed|
  team = File.read(File.join(project.root, "app/models/team.rb"), encoding: Encoding::UTF_8)
  untouched = project.changed(%w[app/models/user.rb app/models/account.rb])
  renamed = team.include?("def display_name") && !team.include?("def full_name")
  { "pass" => renamed && untouched.empty?,
    "output" => "team.rb #{renamed ? "renamed" : "still defines full_name"}; changed elsewhere: #{untouched.inspect}" }
end
