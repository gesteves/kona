require_relative "../utils/index_now"

namespace :indexnow do
  # The deploy runs this after the edge purge, thus each URL is live before an engine reads it.
  # `rake indexnow:submit[all]` sends the full sitemap, which is for the first submission only.
  # DRY_RUN=1 prints the URLs and posts nothing.
  desc "Submit the URLs that changed since the last submission to IndexNow"
  task :submit, [ :scope ] => [ :dotenv ] do |_task, args|
    key = ENV["INDEXNOW_KEY"].to_s.strip
    site_url = ENV["URL"].to_s.strip
    sitemap = File.join(BUILD_DIRECTORY, "sitemap.xml")

    if key.empty?
      puts "IndexNow: INDEXNOW_KEY has no value, thus this run submitted nothing."
    elsif site_url.empty?
      puts "IndexNow: URL has no value, thus this run submitted nothing."
    elsif !File.exist?(sitemap)
      puts "IndexNow: #{sitemap} does not exist. Run `rake build` first."
    else
      IndexNow.submit(
        sitemap_path: sitemap,
        site_url: site_url,
        key: key,
        all: args[:scope] == "all",
        dry_run: !ENV["DRY_RUN"].to_s.empty?
      )
    end
  end
end
