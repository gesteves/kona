require "json"

DATA_DIRECTORY = "data"

# Removes each data file from an earlier import.
CLOBBER.include %w[ data/*.json ]

# Each import: the line that the output shows, and the code. `optional: true` is for an import
# that must not stop the build: an improvement, or the data of a third party. A content deploy
# must not wait for an api or a third party that is unavailable for a short time. An import with
# no flag stops the build when it fails, because each page needs its data.
IMPORTS = {
  content: { description: "Importing site content", run: -> { Contentful.new.save_data } },
  icons: { description: "Importing icons", run: -> { ApiImports.icons } },
  standard_site: { description: "Fetching standard.site verification data", run: -> { ApiImports.standard_site }, optional: true },
  related: { description: "Fetching related articles", run: -> { ApiImports.related }, optional: true },
  known_agents: { description: "Importing robots.txt directives", run: -> { KnownAgents.import }, optional: true },
  schema: { description: "Writing the Contentful schema", run: -> { ContentfulClient.write_schema }, optional: true }
}.freeze

# Loads the importers of lib/data/.
#
# ⚠️ This is a task, and not a require at the top of the Rakefile. The Contentful client reads its
# schema when the file loads, from the network when the schema file is absent. Thus only an
# import needs that, and `rake test` and `rake build:fast` need no credentials.
task :importers do
  Dir[File.expand_path("../data/*.rb", __dir__)].sort.each { |file| require file }
end

namespace :import do
  desc "Imports FontAwesome icons"
  task icons: [ :dotenv, :importers ] do
    setup_data_directory
    run_import(:icons)
  end

  desc "Imports Contentful content"
  task content: [ :dotenv, :importers ] do
    setup_data_directory
    run_import(:content)
  end

  desc "Fetches standard.site verification data (DID + publication URI) from the api"
  task standard_site: [ :dotenv, :importers ] do
    setup_data_directory
    run_import(:standard_site)
  end

  desc "Writes the Contentful GraphQL schema to lib/data/graphql/contentful_schema.json"
  task schema: [ :dotenv, :importers ] do
    run_import(:schema)
  end

  desc "Fetches the related-articles ranking from the api"
  task related: [ :dotenv, :importers ] do
    setup_data_directory
    run_import(:related)
    report_related_coverage
  end

  desc "Fetches the robots.txt rules that block the AI scrapers from Known Agents"
  task known_agents: [ :dotenv, :importers ] do
    setup_data_directory
    run_import(:known_agents)
  end
end

desc "Imports all content for the site"
task import: [ :dotenv, :clobber, :importers ] do
  puts "=" * 60
  puts "🚀 Starting full site data import"
  puts "=" * 60

  overall_start_time = Time.now
  setup_data_directory

  output_mutex = Mutex.new

  # The imports do not depend on each other, thus they run at the same time.
  IMPORTS.keys.map { |name| Thread.new { run_import(name, mutex: output_mutex) } }.each(&:join)

  # This runs after the join, because it reads the output of two importers that run at the same
  # time.
  report_related_coverage

  total_duration = Time.now - overall_start_time
  puts "\n" + "=" * 60
  puts "🎉 Import completed! Total time: #{format_duration(total_duration)}"
  puts "=" * 60
end

def setup_data_directory
  FileUtils.mkdir_p(DATA_DIRECTORY)
end

# The part of the archive that needs a related list before the build reports one that is thin.
# The two apps read Contentful separately, thus a small skew between them is normal.
RELATED_COVERAGE_FLOOR = 0.8

# Reports a related-articles file that is absent or thin. It does NOT stop the build.
#
# ⚠️ A non-2xx answer to ApiImports.related gives no message, and each article then loses four
# internal links. This report shows that failure.
def report_related_coverage
  articles = JSON.parse(File.read("data/articles.json")) rescue nil
  return if articles.nil?

  expected = articles.count { |a| !a["draft"] }
  return if expected.zero?

  related = JSON.parse(File.read("data/related.json")) rescue nil
  if related.nil?
    puts "⚠️  data/related.json is absent. Each article loses its “You May Also Like” section."
    return
  end

  # ⚠️ A key says "the api ranked this entry", and an empty list says "the api found no candidate
  # at all". Those two are different. The api makes its index from the same content that it reads
  # for the list, thus each published entry gets a key and no list is short.
  covered = related.size
  empty = related.count { |_id, ids| Array(ids).empty? }

  if empty.positive?
    puts "⚠️  #{empty} of #{covered} entries got an empty list. Run `rake related:audit` in the api."
  end

  return if covered >= expected * RELATED_COVERAGE_FLOOR

  puts "⚠️  The api ranked #{covered} of #{expected} entries. Run `rake related:audit` in the api."
end

# Runs one import of IMPORTS and prints its result.
#
# ⚠️ Only this method prints, through the mutex, with the name of the import. A print in an
# importer would go between the lines of the other threads.
# @param name [Symbol] A key of IMPORTS.
# @param mutex [Mutex, nil] The lock of the output, when the imports run at the same time.
def run_import(name, mutex: nil)
  import = IMPORTS.fetch(name)
  description = import[:description]
  log = ->(msg) { mutex ? mutex.synchronize { puts msg } : puts(msg) }

  log.call("\n🔄 #{description}...")
  start_time = Time.now

  begin
    import[:run].call
    log.call("✅ #{description} completed in #{format_duration(Time.now - start_time)}")
  rescue => e
    duration = format_duration(Time.now - start_time)
    if import[:optional]
      # The build goes on, and this line is what says that the data of that import is absent.
      log.call("⚠️  #{description} did not complete after #{duration}")
      log.call("   Error: #{e.class}: #{e.message}")
    else
      log.call("❎ #{description} failed after #{duration}")
      log.call("   Error: #{e.message}")
      # This stops the build here, and not with an unclear error on each page later.
      raise
    end
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
