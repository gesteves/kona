require 'httparty'
require 'yaml'

DATA_DIRECTORY = 'data'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

namespace :import do
  desc 'Imports FontAwesome icons'
  task :icons => [:dotenv] do
    setup_data_directory
    measure_and_output(:import_font_awesome, "Importing icons")
  end

  desc 'Imports Contentful content'
  task :content => [:dotenv] do
    setup_data_directory
    RedisConnection.connection
    measure_and_output(:import_contentful, "Importing site content")
  end

  desc 'Fetches standard.site verification data (DID + publication URI) from the api'
  task :standard_site => [:dotenv] do
    setup_data_directory
    RedisConnection.connection
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
  RedisConnection.connection

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

# Number of icons requested per /api/icons call. The api resolves each cache-missed icon from
# Font Awesome (~100ms each), and it caps total request time (rack-timeout) so one slow request
# can't hog a Puma thread. Requesting the whole ~150-icon allowlist at once blows that budget on
# a cold cache (e.g. right after a Font Awesome version bump), so we ask in small batches each of
# which the api can comfortably resolve in time; warm-cache batches are near-instant.
ICON_IMPORT_BATCH_SIZE = 25

# Fetches pre-rendered icon SVGs from the api's /api/icons endpoint and writes data/icons.json
# (the family → style → [{id, svg}] tree the icon_svg helper reads via data.icons). The web
# build no longer talks to Font Awesome directly — the FA integration (token, GraphQL, version,
# cache) lives only in the api. web/ still owns the allowlist (data/font_awesome.yml): its icons
# tree is POSTed to the api in batches, which resolves each id on demand. Unlike standard.site,
# icons are an every-page dependency, so any failure raises to fail the build loudly rather than
# shipping a site with missing icons.
def import_font_awesome
  base = ENV['KONA_API_URL'].to_s.chomp('/')
  raise 'KONA_API_URL is not set; cannot fetch icons from the api' if base.blank?

  allowlist = YAML.load_file('data/font_awesome.yml')['icons'] || {}
  # Flatten to [family, style, id] triples in allowlist order; uniq collapses the few duplicate
  # ids so a batch boundary can't make one show up twice in the merged output.
  triples = allowlist.flat_map do |family, styles|
    (styles || {}).flat_map { |style, ids| Array(ids).map { |id| [family, style, id] } }
  end.uniq

  icons = {}
  triples.each_slice(ICON_IMPORT_BATCH_SIZE) do |batch|
    tree = batch.each_with_object({}) do |(family, style, id), acc|
      ((acc[family] ||= {})[style] ||= []) << id
    end
    # Merge each batch's result, appending in order so the output matches the allowlist order.
    fetch_icons_batch(base, tree).each do |family, styles|
      styles.each do |style, entries|
        ((icons[family] ||= {})[style] ||= []).concat(entries)
      end
    end
  end

  raise 'Icon import returned no icons from the api' if icons.blank?

  File.write('data/icons.json', icons.to_json)
end

# POSTs one batch (a { family => { style => [ids] } } tree) to the api and returns the parsed
# { family => { style => [{ "id", "svg" }] } } result. Raises on a non-2xx so the build fails loud.
def fetch_icons_batch(base, tree)
  response = HTTParty.post(
    "#{base}/api/icons",
    headers: {
      'Authorization' => "Bearer #{ENV['API_TOKEN']}",
      'Content-Type' => 'application/json'
    },
    body: { icons: tree }.to_json,
    timeout: 30
  )
  raise "Icon import failed: HTTP #{response.code} from #{base}/api/icons" unless response.success?

  JSON.parse(response.body)
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
    # Re-raise so an essential import (e.g. icons, an every-page dependency) fails the build
    # loudly here instead of surfacing later as a cryptic per-page middleman error. Imports
    # that are meant to degrade gracefully (standard.site) swallow their own errors internally
    # via safely_perform, so they never reach this rescue.
    raise
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
