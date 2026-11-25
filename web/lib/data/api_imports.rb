require "active_support/all"
require "httparty"
require "json"
require "yaml"

# The data that the build gets from the api app: the icons, the related articles, and the
# standard.site verification data. Each method writes one file in data/.
module ApiImports
  # The number of icons in one /api/icons call. The api gets each icon that is not in the cache
  # from Font Awesome, and it has a maximum request time. Thus the full list in one request goes
  # past that time when the cache is empty.
  ICON_BATCH_SIZE = 25

  # The number of attempts after a failed icon group, and the time to wait before each attempt.
  #
  # ⚠️ The api runs on fly machines that stop by themselves, thus the first request of a build can
  # fail while the origin starts. A failed icon import stops the build, on purpose. A cold start
  # takes some seconds, thus these waits cover it and do not hide an origin that is truly broken.
  ICON_MAX_RETRIES = 3
  ICON_RETRY_DELAYS = [ 2, 5, 10 ].freeze

  class << self
    # Posts the list in data/font_awesome.yml to the api, in groups, and writes data/icons.json.
    # That file is the family → style → [{id, svg}] tree that the icon_svg helper reads. Each page
    # needs the icons, thus a failure raises and stops the build, and the build does not go to
    # production with an icon that is absent.
    def icons
      base = base_url
      raise "KONA_API_URL is not set; cannot fetch icons from the api" if base.blank?

      allowlist = YAML.load_file("data/font_awesome.yml")["icons"] || {}
      # uniq removes each id that is the same, thus the limit of a group cannot write one id two
      # times.
      triples = allowlist.flat_map do |family, styles|
        (styles || {}).flat_map { |style, ids| Array(ids).map { |id| [ family, style, id ] } }
      end.uniq

      icons = {}
      triples.each_slice(ICON_BATCH_SIZE) do |batch|
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

    # Gets the standard.site DID and the publication URI from the api and writes them to
    # data/standard_site.json, for the .well-known endpoint and for the verification link tags.
    # With no api URL, and on a non-2xx answer, it writes nothing and gives no message, and the
    # templates then omit the markup.
    def standard_site
      base = base_url
      return if base.blank?

      response = HTTParty.get("#{base}/api/standard-site", timeout: 15)
      return unless response.success? && response.body.present?

      data = JSON.parse(response.body)
      return if data["publication_uri"].blank?

      File.write("data/standard_site.json", { did: data["did"], publication_uri: data["publication_uri"] }.to_json)
    end

    # Gets the related-article ids of each entry from the api and writes them to data/related.json.
    # RecirculationHelpers#related_articles renders that data as the "You May Also Like" section of
    # each article.
    #
    # With no api URL, and on a non-2xx answer, it writes nothing and gives no message, as
    # .standard_site does, and the section is then absent.
    def related
      base = base_url
      return if base.blank?

      response = HTTParty.get("#{base}/api/related", headers: { "Authorization" => "Bearer #{ENV['API_TOKEN']}" }, timeout: 15)
      return unless response.success? && response.body.present?

      related = JSON.parse(response.body)
      return unless related.is_a?(Hash) && related.present?

      File.write("data/related.json", related.to_json)
    end

    private

    # @return [String] The origin of the api, with no slash at the end, or "" when it has no value.
    def base_url
      ENV["KONA_API_URL"].to_s.chomp("/")
    end

    # Posts one { family => { style => [ids] } } group to the api. On a failure it waits, then
    # tries again.
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
        raise if attempt > ICON_MAX_RETRIES

        delay = ICON_RETRY_DELAYS[attempt - 1]
        warn "Icon import attempt #{attempt} failed (#{e.message}); retrying in #{delay}s"
        sleep delay
        retry
      end
    end
  end
end
