require "json"
require "uri"
require "httparty"
require "nokogiri"
require_relative "redis_connection"

# Sends the URLs that changed to IndexNow, which gives them to each participating search engine.
# The deploy calls it after the edge purge, thus each URL is already live.
#
# The state is one Redis key that holds the sitemap of the last submission, as a map of a URL to its
# lastmod. The changed set is the URLs that are new and the URLs whose lastmod moved. Thus a deploy
# with no content change sends nothing.
module IndexNow
  # The shared endpoint. It gives each URL to every participating engine, thus one POST is enough.
  ENDPOINT = "https://api.indexnow.org/indexnow".freeze
  # The map of the last submission, in the Redis of the build.
  REDIS_KEY = "indexnow:sitemap".freeze
  # The name of the key file at the root of the site. source/indexnow.txt.erb renders it.
  KEY_FILENAME = "indexnow.txt".freeze
  # The limit of the protocol for one POST.
  MAX_URLS = 10_000
  # The statuses that correct themselves. Each other failure is a configuration error.
  TEMPORARY_STATUSES = (500..599).to_a.push(429).freeze

  # The key, the keyLocation, or the host is incorrect. A person must correct it.
  class ConfigurationError < StandardError; end

  class << self
    # Submits the URLs that changed since the last submission.
    # @param sitemap_path [String] The path of the sitemap that the build wrote.
    # @param site_url [String] The public origin of the site.
    # @param key [String] The IndexNow key.
    # @param all [Boolean] true submits each URL in the sitemap, and not the changed URLs only.
    # @param dry_run [Boolean] true prints the URLs and posts nothing.
    # @param logger [#call] Takes one line of text.
    # @return [Array<String>] The URLs that this call submitted.
    def submit(sitemap_path:, site_url:, key:, all: false, dry_run: false, logger: method(:puts))
      current = parse_sitemap(sitemap_path)
      raise ConfigurationError, "#{sitemap_path} lists no URL." if current.empty?

      current = same_host_only(current, site_url, logger)
      raise ConfigurationError, "No URL in #{sitemap_path} is on the host of #{site_url}." if current.empty?

      previous = read_previous

      # ⚠️ The first run seeds the state and submits nothing. The protocol asks for the URLs that
      # changed, and each URL of a site that exists already is not that. Use `all` for a full one.
      if previous.nil? && !all
        write_current(current)
        logger.call("IndexNow: this app never submitted, thus this run stored #{current.size} URLs and submitted none. `rake indexnow:submit[all]` sends the full sitemap.")
        return []
      end

      urls = changed_urls(current, previous, all: all)
      if urls.empty?
        write_current(current)
        logger.call("IndexNow: no URL changed.")
        return []
      end

      if dry_run
        logger.call("IndexNow: DRY_RUN, thus this run submitted none of these #{urls.size} URLs:")
        urls.each { |url| logger.call("  #{url}") }
        return urls
      end

      # ⚠️ Write the map only after a successful POST. A write after a failure loses that change for
      # all time, because the next deploy would then find no difference.
      return [] unless post(urls: urls, site_url: site_url, key: key, logger: logger)

      write_current(current)
      logger.call("IndexNow: submitted #{urls.size} URLs.")
      urls.each { |url| logger.call("  #{url}") }
      urls
    end

    private

    # Reads the loc and the lastmod of each entry of the sitemap.
    # @param path [String] The path of the sitemap.
    # @return [Hash{String => String}] Each URL, and its lastmod or an empty string.
    def parse_sitemap(path)
      document = Nokogiri::XML(File.read(path))
      document.remove_namespaces!
      document.xpath("//url").each_with_object({}) do |node, map|
        loc = node.at_xpath("loc")&.text.to_s.strip
        next if loc.empty?

        map[loc] = node.at_xpath("lastmod")&.text.to_s.strip
      end
    end

    # Removes each URL that is not on the host of the site. IndexNow answers 422 for such a URL, and
    # a build that is not a production build writes localhost URLs into the sitemap.
    # @param current [Hash{String => String}] The sitemap of this build.
    # @param site_url [String] The public origin of the site.
    # @return [Hash{String => String}] The URLs on that host.
    def same_host_only(current, site_url, logger)
      host = URI.parse(site_url.to_s.chomp("/")).host
      kept = current.select { |loc, _| host_of(loc) == host }
      removed = current.size - kept.size
      logger.call("IndexNow: #{removed} of #{current.size} URLs are not on #{host}, thus this run left them out.") if removed.positive?
      kept
    end

    # @param url [String] A URL from the sitemap.
    # @return [String, nil] Its host, or nil when it does not parse.
    def host_of(url)
      URI.parse(url).host
    rescue URI::InvalidURIError
      nil
    end

    # @return [Hash{String => String}, nil] The map of the last submission, or nil when this app
    #   never submitted.
    def read_previous
      stored = RedisConnection.connection.get(REDIS_KEY)
      return nil if stored.nil?

      parsed = JSON.parse(stored)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    # @param current [Hash{String => String}] The sitemap of this build.
    # @return [void]
    def write_current(current)
      RedisConnection.connection.set(REDIS_KEY, JSON.dump(current))
    end

    # @param current [Hash{String => String}] The sitemap of this build.
    # @param previous [Hash{String => String}, nil] The sitemap of the last submission.
    # @param all [Boolean] true gives each URL.
    # @return [Array<String>] The URLs to submit, at the most MAX_URLS of them.
    def changed_urls(current, previous, all:)
      urls = if all || previous.nil?
        current.keys
      else
        current.reject { |loc, lastmod| previous[loc] == lastmod }.keys
      end
      urls.first(MAX_URLS)
    end

    # Sends the URLs.
    # @return [Boolean] true when IndexNow accepted them. false means a failure that corrects
    #   itself, thus the caller must not store the sitemap.
    # @raise [ConfigurationError] The key, the keyLocation, or the host is incorrect.
    def post(urls:, site_url:, key:, logger:)
      origin = site_url.to_s.chomp("/")
      body = {
        host: URI.parse(origin).host,
        key: key,
        keyLocation: "#{origin}/#{KEY_FILENAME}",
        urlList: urls
      }

      response = HTTParty.post(
        ENDPOINT,
        headers: { "Content-Type" => "application/json; charset=utf-8" },
        body: JSON.dump(body)
      )
      return true if response.success?

      # 429 and each 5xx go away by themselves, and the next deploy finds the same difference and
      # sends it again. Each other status means that a person must change something: 403 and 422 are
      # a key or a host that does not match the file at KEY_FILENAME.
      raise ConfigurationError, "IndexNow refused the submission (HTTP #{response.code}): #{response.body}" unless TEMPORARY_STATUSES.include?(response.code.to_i)

      defer(logger, urls.size, "HTTP #{response.code}")
    rescue SocketError, SystemCallError, Timeout::Error, HTTParty::Error => e
      defer(logger, urls.size, e.message)
    end

    # Reports a failure that corrects itself, and does not raise.
    # @return [false]
    def defer(logger, count, reason)
      logger.call("::warning::IndexNow: the submission of #{count} URLs failed (#{reason}). The next deploy sends them again.")
      false
    end
  end
end
