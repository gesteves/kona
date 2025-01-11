namespace :redis do
  desc 'Empties the Redis instance after confirmation'
  task :clear do
    puts 'WARNING: You are about to completely empty the Redis instance. This action is irreversible!'
    print 'Type "execute" to proceed: '
    confirmation = STDIN.gets.strip
    if confirmation.downcase == 'execute'
      $redis.flushdb
      puts 'Redis instance has been emptied.'
    else
      puts 'Redis empty action cancelled.'
    end
  end
end
