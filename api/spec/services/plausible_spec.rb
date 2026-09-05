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

  describe "#daily_visitors_by_path" do
    let(:today) { Date.new(2026, 6, 15) }

    # One row for each day and each page, and today is a partial day inside the range.
    it "asks for the visitors of each day and each page in a single query" do
      expect(service).to receive(:post_json).once do |_url, **options|
        body = JSON.parse(options[:body])
        expect(body["dimensions"]).to eq([ "time:day", "event:page" ])
        expect(body["metrics"]).to eq([ "visitors" ])
        expect(body["date_range"]).to eq([ "2026-03-10", "2026-06-15" ])
        expect(body["filters"]).to eq([ [ "matches", "event:page", [ "^/20\\d{2}/" ] ] ])
        { results: [] }
      end

      service.daily_visitors_by_path(days: 97, today: today)
    end

    it "folds the rows into { path => { day => visitors } }" do
      allow(service).to receive(:post_json).and_return(results: [
        { dimensions: [ "2026-06-14", "/2026/05/01/a/" ], metrics: [ 4 ] },
        { dimensions: [ "2026-06-15", "/2026/05/01/a/" ], metrics: [ 6 ] },
        { dimensions: [ "2026-06-15", "/2026/05/02/b/" ], metrics: [ 1 ] }
      ])

      expect(service.daily_visitors_by_path(days: 7, today: today)).to eq(
        "/2026/05/01/a/" => { Date.new(2026, 6, 14) => 4, Date.new(2026, 6, 15) => 6 },
        "/2026/05/02/b/" => { Date.new(2026, 6, 15) => 1 }
      )
    end

    it "sums the trailing-index.html form into the clean path" do
      allow(service).to receive(:post_json).and_return(results: [
        { dimensions: [ "2026-06-15", "/2026/05/01/a/" ], metrics: [ 4 ] },
        { dimensions: [ "2026-06-15", "/2026/05/01/a/index.html" ], metrics: [ 2 ] }
      ])

      expect(service.daily_visitors_by_path(days: 7, today: today)).to eq("/2026/05/01/a/" => { Date.new(2026, 6, 15) => 6 })
    end

    it "skips a row with a day that it cannot parse" do
      allow(service).to receive(:post_json).and_return(results: [
        { dimensions: [ "never", "/2026/05/01/a/" ], metrics: [ 4 ] }
      ])

      expect(service.daily_visitors_by_path(days: 7, today: today)).to eq({})
    end

    it "returns nil when the query is unavailable" do
      allow(service).to receive(:post_json).and_return(nil)

      expect(service.daily_visitors_by_path(days: 7, today: today)).to be_nil
    end
  end

  describe "#covisit_visitors" do
    it "asks for the entry page and the page in a single query" do
      expect(service).to receive(:post_json).once do |_url, **options|
        body = JSON.parse(options[:body])
        expect(body["dimensions"]).to eq([ "visit:entry_page", "event:page" ])
        expect(body["metrics"]).to eq([ "visitors" ])
        expect(body["date_range"]).to eq("all")
        { results: [] }
      end

      service.covisit_visitors
    end

    it "folds the rows into { entry path => { path => visitors } } and omits the same page" do
      allow(service).to receive(:post_json).and_return(results: [
        { dimensions: [ "/2026/05/01/a/", "/2026/05/01/a/" ], metrics: [ 40 ] },
        { dimensions: [ "/2026/05/01/a/", "/2026/05/02/b" ], metrics: [ 3 ] },
        { dimensions: [ "/2026/05/01/a/", "/2026/05/02/b/" ], metrics: [ 2 ] }
      ])

      expect(service.covisit_visitors).to eq("/2026/05/01/a/" => { "/2026/05/02/b/" => 5 })
    end

    it "returns nil when the query is unavailable" do
      allow(service).to receive(:post_json).and_return(nil)

      expect(service.covisit_visitors).to be_nil
    end
  end
end
