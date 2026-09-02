# The configuration DSL of Puma. @see https://puma.io/puma/Puma/DSL.html
# One process, with RAILS_MAX_THREADS threads. There are no workers: the machine has one shared
# CPU and 512MB.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 3000)

# This lets `bin/rails restart` restart Puma.
plugin :tmp_restart

pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
