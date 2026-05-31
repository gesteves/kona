require 'httparty'

DATA_DIRECTORY = 'data'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

namespace :import do
  desc 'Imports FontAwesome icons'
  task :icons => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_font_awesome, "Importing icons")
  end

  desc 'Imports Contentful content'
  task :content => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_contentful, "Importing site content")
  end

  desc 'Imports location data'
  task :location => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_location, "Importing location data")
  end

  desc 'Syncs standard.site records to the PDS (requires content to be imported first)'
  task :standard_site => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_standard_site, "Syncing standard.site records")
  end

end

desc 'Imports all content for the site'
task :import => [:dotenv, :clobber] do
  puts "=" * 60
  puts "🚀 Starting full site data import"
  puts "=" * 60

  overall_start_time = Time.now
  setup_data_directory
  initialize_redis

  output_mutex = Mutex.new

  # Independent imports that can run in parallel.
  independent_threads = [
    [:import_contentful, "Importing site content"],
    [:import_font_awesome, "Importing icons"],
    [:import_location, "Importing location data"]
  ].map do |method, description|
    Thread.new do
      measure_and_output(method, description, mutex: output_mutex)
    end
  end

  # Wait for all threads to complete
  independent_threads.each(&:join)

  # Runs after the parallel imports so it can read the freshly-written
  # data/articles.json and data/site.json. No-ops outside production.
  measure_and_output(:import_standard_site, "Syncing standard.site records", mutex: output_mutex)

  total_duration = Time.now - overall_start_time
  puts "\n" + "=" * 60
  puts "🎉 Import completed! Total time: #{format_duration(total_duration)}"
  puts "=" * 60
end

def setup_data_directory
  FileUtils.mkdir_p(DATA_DIRECTORY)
end

def import_contentful
  Contentful.new.save_data
end

def import_font_awesome
  FontAwesome.new.save_data
end

# Fetches the current location (geocoded into geocoded/time_zone/elevation) from the API —
# the source of truth — and writes it to data/location.json. Always writes a valid file so
# data.location is present even when the API is unreachable.
def import_location
  body = begin
    response = HTTParty.get("#{ENV['KONA_API_URL']}/api/location")
    response.success? ? response.body : nil
  rescue StandardError
    nil
  end
  body ||= '{"geocoded":null,"time_zone":null,"elevation":null}'
  File.open('data/location.json', 'w') { |f| f << body }
end

def import_standard_site
  safely_perform { StandardSite.new.save_data }
end

def safely_perform
  yield
rescue => e
  puts "Error occurred: #{e.message}"
end

def measure_and_output(method, description, mutex: nil)
  log = ->(msg) { mutex ? mutex.synchronize { puts msg } : puts(msg) }

  log.call("\n🔄 #{description}...")
  start_time = Time.now

  begin
    send(method)
    duration = Time.now - start_time
    log.call("✅ #{description} completed in #{format_duration(duration)}")
  rescue => e
    duration = Time.now - start_time
    log.call("❎ #{description} failed after #{format_duration(duration)}")
    log.call("   Error: #{e.message}")
  end
end

def format_duration(seconds)
  if seconds < 1
    "#{(seconds * 1000).round}ms"
  elsif seconds < 60
    "#{seconds.round(2)}s"
  else
    minutes = (seconds / 60).floor
    remaining_seconds = (seconds % 60).round
    "#{minutes}m #{remaining_seconds}s"
  end
end
