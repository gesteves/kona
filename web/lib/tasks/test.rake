desc 'Run the test suite'
task :test do
  puts 'Running tests...'
  sh 'bundle exec rspec'
end
