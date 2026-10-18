# The `$BROWSER` stub of the launcher's tests: writes the URL it was
# handed (its last argument) to the file named by its first.
File.write(ARGV.fetch(0), ARGV.fetch(1))
