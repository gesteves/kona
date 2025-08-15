namespace :oauth do
  desc 'Setup Whoop OAuth tokens'
  task :whoop => [:dotenv] do
    initialize_redis
    WhoopOAuth.new.run
  end
end