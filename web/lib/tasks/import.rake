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

  desc 'Fetches standard.site verification data (DID + publication URI) from the api'
  task :standard_site => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_standard_site, "Fetching standard.site verification data")
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

  # Independent imports that can run in parallel. standard.site no longer depends on the
  # Contentful import — it just fetches the DID/publication URI from the api.
  independent_threads = [
    [:import_contentful, "Importing site content"],
    [:import_font_awesome, "Importing icons"],
    [:import_standard_site, "Fetching standard.site verification data"]
  ].map do |method, description|
    Thread.new do
      measure_and_output(method, description, mutex: output_mutex)
    end
  end

  # Wait for all threads to complete
  independent_threads.each(&:join)

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

# Fetches the standard.site verification data (DID + publication URI) from the api and
# writes data/standard_site.json so the build can emit the .well-known endpoint and the
# <link rel="site.standard.*"> tags. The PDS sync itself now lives in the api (webhook-
# driven). On any failure (api unreachable, non-2xx, empty body, no credentials) this
# writes nothing and the verification templates simply omit the markup.
def import_standard_site
  safely_perform do
    base = ENV['KONA_API_URL'].to_s.chomp('/')
    next if base.blank?
    response = HTTParty.get("#{base}/api/standard-site")
    next unless response.success? && response.body.present?
    data = JSON.parse(response.body)
    next if data['publication_uri'].blank?
    File.write('data/standard_site.json', { did: data['did'], publication_uri: data['publication_uri'] }.to_json)
  end
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
