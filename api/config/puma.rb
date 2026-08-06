# Puma's configuration DSL. @see https://puma.io/puma/Puma/DSL.html
# Worker count comes from WEB_CONCURRENCY; threads per worker from RAILS_MAX_THREADS.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

# Lets `bin/rails restart` restart Puma.
plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
