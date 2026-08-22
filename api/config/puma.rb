# The configuration DSL of Puma. @see https://puma.io/puma/Puma/DSL.html
# WEB_CONCURRENCY gives the number of workers, and RAILS_MAX_THREADS gives the number of threads in
# each worker.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

# This lets `bin/rails restart` restart Puma.
plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
