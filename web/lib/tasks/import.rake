require "httparty"
require "yaml"

DATA_DIRECTORY = "data"

# Removes each data file from an earlier import.
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

  desc "Fetches the related-articles ranking from the api"
  task related: [ :dotenv ] do
    setup_data_directory
    RedisConnection.connection
    measure_and_output(:import_related, "Fetching related articles")
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

  # These do not depend on each other, thus they run at the same time.
  independent_threads = [
    [ :import_contentful, "Importing site content" ],
    [ :import_font_awesome, "Importing icons" ],
    [ :import_standard_site, "Fetching standard.site verification data" ],
    [ :import_related, "Fetching related articles" ]
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

# The number of icons in one /api/icons call. The api gets each icon that is not in the cache from
# Font Awesome, and it has a maximum request time. Thus the full list in one request goes past that
# time when the cache is empty.
ICON_IMPORT_BATCH_SIZE = 25

# Posts the list in data/font_awesome.yml to the api, in groups, and writes data/icons.json. That
# file is the family → style → [{id, svg}] tree that the icon_svg helper reads. Each page needs the
# icons, thus a failure raises and stops the build, and the build does not go to production with an
# icon that is absent.
def import_font_awesome
  base = ENV["KONA_API_URL"].to_s.chomp("/")
  raise "KONA_API_URL is not set; cannot fetch icons from the api" if base.blank?

  allowlist = YAML.load_file("data/font_awesome.yml")["icons"] || {}
  # uniq removes each id that is the same, thus the limit of a group cannot write one id two
  # times.
  triples = allowlist.flat_map do |family, styles|
    (styles || {}).flat_map { |style, ids| Array(ids).map { |id| [ family, style, id ] } }
  end.uniq

  icons = {}
  triples.each_slice(ICON_IMPORT_BATCH_SIZE) do |batch|
    tree = batch.each_with_object({}) do |(family, style, id), acc|
      ((acc[family] ||= {})[style] ||= []) << id
    end
    # The code adds them in order, thus the output has the same order as the list.
    fetch_icons_batch(base, tree).each do |family, styles|
      styles.each do |style, entries|
        ((icons[family] ||= {})[style] ||= []).concat(entries)
      end
    end
  end

  raise "Icon import returned no icons from the api" if icons.blank?

  File.write("data/icons.json", icons.to_json)
end

# The number of attempts after a failed icon group, and the time to wait before each attempt.
#
# ⚠️ This exists because the api runs on fly machines that stop by themselves. A Contentful publish
# starts a build, and if that build comes while the origin starts, the first request can fail. A
# failed icon import stops the build, on purpose, because each page needs the icons. Thus one cold
# start would stop the full deploy. A cold start takes some seconds, thus two attempts with a wait
# are sufficient, and they do not hide an origin that is truly broken.
ICON_IMPORT_MAX_RETRIES = 3
ICON_IMPORT_RETRY_DELAYS = [ 2, 5, 10 ].freeze

# Posts one { family => { style => [ids] } } group to the api. On a failure it waits, then tries
# again.
# @return [Hash] { family => { style => [{ "id", "svg" }] } }. It raises after the last attempt.
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

# Gets the standard.site DID and the publication URI from the api and writes them to
# data/standard_site.json, for the .well-known endpoint and for the verification link tags.
# On a failure it writes nothing and gives no message, and the templates then omit the markup.
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

# Gets the related-article ids of each entry from the api and writes them to data/related.json.
# ArticleHelpers#related_articles renders that data as the "You May Also Like" section of each
# article.
#
# On a failure it writes nothing and gives no message, as import_standard_site does, and the section
# is then absent. ⚠️ This does NOT stop the build, on purpose. The list is an improvement, and an api
# that is unavailable for a short time must not stop a content deploy. An icon that is absent is
# different.
def import_related
  safely_perform do
    base = ENV["KONA_API_URL"].to_s.chomp("/")
    next if base.blank?
    response = HTTParty.get("#{base}/api/related", headers: { "Authorization" => "Bearer #{ENV['API_TOKEN']}" })
    next unless response.success? && response.body.present?
    related = JSON.parse(response.body)
    next unless related.is_a?(Hash) && related.present?
    File.write("data/related.json", related.to_json)
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
    # This stops the build here, and not with an unclear error on each page later. An import that
    # must continue after a failure catches its own errors with safely_perform and never comes
    # here.
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
