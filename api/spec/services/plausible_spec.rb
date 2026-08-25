require "rails_helper"

RSpec.describe Plausible do
  subject(:service) { described_class.new }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PLAUSIBLE_API_KEY").and_return("key")
    allow(ENV).to receive(:[]).with("PLAUSIBLE_SITE_ID").and_return("example.com")

    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  # { path => pageviews } becomes the event:page rows that Plausible returns. The all-time query
  # asks for the visitors first and the pageviews second, thus each row holds two values.
  def rows(by_path, visitors = {})
    by_path.map do |path, total|
      { dimensions: [ path ], metrics: [ visitors[path].to_i, total ] }
    end
  end

  # The rows of the entry-page query, which asks for the visitors only.
  def entry_rows(by_path)
    by_path.map { |path, total| { dimensions: [ path ], metrics: [ total ] } }
  end

  describe "#pageviews_by_path" do
    it "folds event:page rows into { path => pageviews }" do
      allow(service).to receive(:post_json)
        .and_return(results: rows("/2026/05/01/a/" => 12, "/2026/05/02/b/" => 300))

      expect(service.pageviews_by_path).to eq("/2026/05/01/a/" => 12, "/2026/05/02/b/" => 300)
    end

    it "defaults an unseen path to zero rather than nil" do
      allow(service).to receive(:post_json).and_return(results: rows("/2026/05/01/a/" => 12))

      expect(service.pageviews_by_path["/2026/05/09/never-viewed/"]).to eq(0)
    end

    # A query for each article would make the number of calls grow with the number of articles, and
    # it would go past the limit of Plausible of 600 calls each hour, at the 5-minute TTL of the
    # widget. Refer to Widgets::PlausibleController.
    it "asks for every article page in a single query" do
      expect(service).to receive(:post_json).once do |_url, **options|
        body = JSON.parse(options[:body])
        expect(body["dimensions"]).to eq([ "event:page" ])
        expect(body["metrics"]).to eq([ "visitors", "pageviews" ])
        expect(body["date_range"]).to eq("all")
        expect(body["filters"]).to eq([ [ "matches", "event:page", [ "^/20\\d{2}/" ] ] ])
        { results: [] }
      end

      service.pageviews_by_path
    end

    it "sums the trailing-index.html form into the clean path" do
      allow(service).to receive(:post_json)
        .and_return(results: rows("/2026/05/01/a/" => 12, "/2026/05/01/a/index.html" => 3))

      expect(service.pageviews_by_path).to eq("/2026/05/01/a/" => 15)
    end

    it "skips rows with a blank path" do
      allow(service).to receive(:post_json)
        .and_return(results: rows("/2026/05/01/a/" => 12) + [ { dimensions: [ nil ], metrics: [ 9 ] } ])

      expect(service.pageviews_by_path).to eq("/2026/05/01/a/" => 12)
    end

    it "returns an empty hash when the query succeeds with no rows" do
      allow(service).to receive(:post_json).and_return(results: [])

      expect(service.pageviews_by_path).to eq({})
    end

    # The difference between nil and {} is what lets a caller know "the analytics are down", where
    # the widget goes away, from "nobody read the page", where the widget shows a count of zero.
    it "returns nil when the query is unavailable" do
      allow(service).to receive(:post_json).and_return(nil)

      expect(service.pageviews_by_path).to be_nil
    end

    it "returns nil when unconfigured, without calling the API" do
      allow(ENV).to receive(:[]).with("PLAUSIBLE_API_KEY").and_return(nil)
      expect(service).not_to receive(:post_json)

      expect(service.pageviews_by_path).to be_nil
    end
  end

  describe "#totals_by_path" do
    # ⚠️ One query body gives both metrics. The pageviews widget reads the pageviews and
    # TrendingArticles reads the visitors, thus the two share one key and one call.
    it "gives the visitors and the pageviews of each path from one query" do
      expect(service).to receive(:post_json).once
        .and_return(results: rows({ "/2026/05/01/a/" => 12 }, { "/2026/05/01/a/" => 7 }))

      expect(service.totals_by_path).to eq("/2026/05/01/a/" => { visitors: 7, pageviews: 12 })
    end
  end

  describe "#page_visitors_by_path" do
    # ⚠️ This is the visitors, and it is not the pageviews. Thus a reader who reloads a page, or
    # who reads it again, counts one time, and nobody can raise it by a reload.
    it "takes the visitors out of the event:page query" do
      allow(service).to receive(:post_json)
        .and_return(results: rows({ "/2026/05/01/a/" => 300 }, { "/2026/05/01/a/" => 9 }))

      expect(service.page_visitors_by_path).to eq("/2026/05/01/a/" => 9)
    end

    # ⚠️ It sends the query body of totals_by_path, word for word. The body is the cache key, thus
    # the two share one entry and the blend of TrendingArticles adds no call for a range that the
    # pageviews widget already asks for.
    it "sends the same query body as the pageviews of the same range" do
      bodies = []
      allow(service).to receive(:post_json) do |_url, **options|
        bodies << options[:body]
        { results: [] }
      end

      service.page_visitors_by_path(date_range: "all")
      service.pageviews_by_path(date_range: "all")

      expect(bodies.uniq.size).to eq(1)
    end

    it "returns nil when the query is unavailable" do
      allow(service).to receive(:post_json).and_return(nil)

      expect(service.page_visitors_by_path).to be_nil
    end
  end

  describe "#entry_visitors_by_path" do
    # ⚠️ A session that starts on the article measures the demand from OUTSIDE the site. No click
    # inside the site can change it, thus the trending widget cannot raise it with its own clicks.
    it "asks for the visitors of each entry page in a single query" do
      expect(service).to receive(:post_json).once do |_url, **options|
        body = JSON.parse(options[:body])
        expect(body["dimensions"]).to eq([ "visit:entry_page" ])
        expect(body["metrics"]).to eq([ "visitors" ])
        expect(body["filters"]).to eq([ [ "matches", "visit:entry_page", [ "^/20\\d{2}/" ] ] ])
        { results: [] }
      end

      service.entry_visitors_by_path
    end

    it "folds the rows into { path => visitors }" do
      allow(service).to receive(:post_json)
        .and_return(results: entry_rows("/2026/05/01/a/" => 4, "/2026/05/02/b/" => 9))

      expect(service.entry_visitors_by_path).to eq("/2026/05/01/a/" => 4, "/2026/05/02/b/" => 9)
    end

    # ⚠️ ArticleAttributes.path always writes the slash at the end. Thus a path with no slash would
    # never join to an article, and it would count as zero.
    it "adds the slash at the end of a path that has none" do
      allow(service).to receive(:post_json)
        .and_return(results: entry_rows("/2026/05/01/a" => 4, "/2026/05/01/a/" => 1))

      expect(service.entry_visitors_by_path).to eq("/2026/05/01/a/" => 5)
    end

    it "returns nil when the query is unavailable" do
      allow(service).to receive(:post_json).and_return(nil)

      expect(service.entry_visitors_by_path).to be_nil
    end
  end
end
