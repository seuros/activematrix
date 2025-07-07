require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
  t.warning = true
  t.verbose = true if ENV['VERBOSE']
end

# Modern CI systems can parse Minitest output directly or use minitest-reporters
# Example: TESTOPTS='--junit' rake test
# This will output JUnit XML if minitest-reporters is installed

task default: :test
