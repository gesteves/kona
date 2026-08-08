require "httparty"
require "yaml"

DATA_DIRECTORY = "data"

# Remove all existing data files from previous imports.
CLOBBER.include %w[ data/*.json ]

namespace :import do
  desc "Imports FontAwesome icons"
  task icons: [ :dotenv ] do
    setup_data_directory
    measure_and_output(:import_font_awesome, "Importing icons")
  end

  desc "Imports Contentful content"
  task content: [ :dotenv ] do
    setup_data_directory
    RedisConnection.connection
    measure_and_output(:import_contentful, "Importing site content")
  end

  desc "Fetches standard.site verification data (DID + publication URI) from the api"
  task standard_site: [ :dotenv ] do
    setup_data_directory
    RedisConnection.connection
    measure_and_output(:import_standard_site, "Fetching standard.site verification data")
  end
end

desc "Imports all content for the site"
task import: [ :dotenv, :clobber ] do
  puts "=" * 60
  puts "🚀 Starting full site data import"
  puts "=" * 60

  overall_start_time = Time.now
  setup_data_directory
  RedisConnection.connection

  output_mutex = Mutex.new

  # These three are independent, so they run in parallel.
  independent_threads = [
    [ :import_contentful, "Importing site content" ],
    [ :import_font_awesome, "Importing icons" ],
    [ :import_standard_site, "Fetching standard.site verification data" ]
  ].map do |method, description|
    Thread.new do
      measure_and_output(method, description, mutex: output_mutex)
    end
  end

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

# Icons per /api/icons call. The api resolves each cache-missed icon from Font Awesome and caps
# total request time, so the whole allowlist in one request blows that budget on a cold cache.
ICON_IMPORT_BATCH_SIZE = 25

# POSTs data/font_awesome.yml's allowlist to the api in batches and writes data/icons.json, the
# family → style → [{id, svg}] tree the icon_svg helper reads. Icons are an every-page
# dependency, so any failure raises and fails the build rather than shipping missing icons.
def import_font_awesome
  base = ENV["KONA_API_URL"].to_s.chomp("/")
  raise "KONA_API_URL is not set; cannot fetch icons from the api" if base.blank?

  allowlist = YAML.load_file("data/font_awesome.yml")["icons"] || {}
  # uniq collapses duplicate ids, so a batch boundary can't emit one twice.
  triples = allowlist.flat_map do |family, styles|
    (styles || {}).flat_map { |style, ids| Array(ids).map { |id| [ family, style, id ] } }
  end.uniq

  icons = {}
  triples.each_slice(ICON_IMPORT_BATCH_SIZE) do |batch|
    tree = batch.each_with_object({}) do |(family, style, id), acc|
      ((acc[family] ||= {})[style] ||= []) << id
    end
    # Appended in order, so the output matches the allowlist's order.
    fetch_icons_batch(base, tree).each do |family, styles|
      styles.each do |style, entries|
        ((icons[family] ||= {})[style] ||= []).concat(entries)
      end
    end
  end

  raise "Icon import returned no icons from the api" if icons.blank?

  File.write("data/icons.json", icons.to_json)
end

# How many times to retry a failed icon batch, and how long to wait before each retry.
#
# ⚠️ This exists because the api runs on fly machines that auto-stop. A Contentful publish
# dispatches a build, and if it lands while the origin is cold-starting, the first request can
# fail — and a failed icon import is deliberately fatal (icons are an every-page dependency), so
# one cold start would fail the whole deploy. A cold start is measured in seconds, so a couple of
# backed-off retries covers it without masking a genuinely broken origin.
ICON_IMPORT_MAX_RETRIES = 3
ICON_IMPORT_RETRY_DELAYS = [ 2, 5, 10 ].freeze

# POSTs one { family => { style => [ids] } } batch to the api, retrying a failure with backoff.
# @return [Hash] { family => { style => [{ "id", "svg" }] } }; raises once the retries are spent.
def fetch_icons_batch(base, tree)
  attempt = 0
  begin
    response = HTTParty.post(
      "#{base}/api/icons",
      headers: {
        "Authorization" => "Bearer #{ENV['API_TOKEN']}",
        "Content-Type" => "application/json"
      },
      body: { icons: tree }.to_json,
      timeout: 30
    )
    raise "Icon import failed: HTTP #{response.code} from #{base}/api/icons" unless response.success?

    JSON.parse(response.body)
  rescue StandardError => e
    attempt += 1
    raise if attempt > ICON_IMPORT_MAX_RETRIES

    delay = ICON_IMPORT_RETRY_DELAYS[attempt - 1]
    warn "Icon import attempt #{attempt} failed (#{e.message}); retrying in #{delay}s"
    sleep delay
    retry
  end
end

# Fetches the standard.site DID and publication URI from the api into
# data/standard_site.json, for the .well-known endpoint and the verification link tags.
# Degrades silently: on any failure it writes nothing and the templates omit the markup.
def import_standard_site
  safely_perform do
    base = ENV["KONA_API_URL"].to_s.chomp("/")
    next if base.blank?
    response = HTTParty.get("#{base}/api/standard-site")
    next unless response.success? && response.body.present?
    data = JSON.parse(response.body)
    next if data["publication_uri"].blank?
    File.write("data/standard_site.json", { did: data["did"], publication_uri: data["publication_uri"] }.to_json)
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
    # Fails the build here rather than as a cryptic per-page error later. Imports meant to
    # degrade gracefully swallow their own errors via safely_perform and never reach this.
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
