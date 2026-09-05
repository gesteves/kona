require "rails_helper"

RSpec.describe TrendingArticles do
  include ActiveSupport::Testing::TimeHelpers

  # Makes an article with the fields that Articles#list gives.
  def article(id:, slug:, published_at:, title: "Title", summary: "Summary.", entry_type: "Article", draft: false)
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: title, summary: summary, slug: slug, published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, sys: { id: id }
    )
  end

  # A fixed "now", thus the windows and the cache key are always the same.
  let(:now) { Time.utc(2024, 6, 15, 12, 0, 0) }
  let(:today) { Date.new(2024, 6, 15) }

  # a1 to a4 have no traffic. a5 has a spike: a few visitors today on a baseline of zero. a6 is
  # always popular: 3 visitors each day, which agrees with its own baseline. The app published a5
  # and a6 long before the start of the baseline, thus they have a full baseline.
  let(:art_newest)   { article(id: "a1", slug: "newest",   published_at: "2024-05-30T10:00:00Z") }
  let(:art_april)    { article(id: "a2", slug: "april",    published_at: "2024-04-01T10:00:00Z") }
  let(:art_march)    { article(id: "a3", slug: "march",    published_at: "2024-03-01T10:00:00Z") }
  let(:art_february) { article(id: "a4", slug: "february", published_at: "2024-02-01T10:00:00Z") }
  let(:art_spiking)  { article(id: "a5", slug: "spiking",  published_at: "2024-01-15T10:00:00Z") }
  let(:art_steady)   { article(id: "a6", slug: "steady",   published_at: "2024-01-01T10:00:00Z") }
  let(:art_short)    { article(id: "s1", slug: "short",    published_at: "2024-05-01T10:00:00Z", entry_type: "Short") }
  let(:art_draft)    { article(id: "d1", slug: "draft",    published_at: "2024-05-02T10:00:00Z", draft: true) }

  let(:corpus) { [ art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short, art_draft ] }

  # { days ago => visitors } for one path.
  def daily(by_days_ago)
    by_days_ago.to_h { |ago, visitors| [ today - ago, visitors ] }
  end

  # The same number of visitors on each of the last `days` days.
  def steady(per_day, days: described_class::SERIES_DAYS + 1)
    (0...days).to_h { |ago| [ today - ago, per_day ] }
  end

  let(:series) { { art_spiking.path => daily(0 => 6), art_steady.path => steady(3) } }
  # The visitors of all time. They order the fill after the recent visitors.
  let(:all_time) { {} }

  let(:articles_service) { instance_double(Articles, list: corpus) }
  let(:plausible_service) { instance_double(Plausible, site_today: today) }
  subject(:service) { described_class.new(articles: articles_service, plausible: plausible_service) }

  before { travel_to(now) }
  after { travel_back }

  before do
    # The fixture has few articles, thus the exclusion of the newest ones is off. One example
    # below turns it on.
    stub_const("TrendingArticles::RECENT_EXCLUDED", 0)
    stub_plausible(series: series, all_time: all_time)
    # cached_json puts the list in the cache. This stubs Redis, thus the suite needs no Redis and
    # each example is separate.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  def stub_plausible(series:, all_time: {})
    allow(plausible_service).to receive(:daily_visitors_by_path).and_return(series)
    allow(plausible_service).to receive(:totals_by_path)
      .and_return(all_time.transform_values { |visitors| { visitors: visitors, pageviews: visitors } })
  end

  def ids(count: 10)
    service.all(count: count).map { |a| a.sys.id }
  end

  def row(id)
    service.evaluate.find { |r| r[:article].sys.id == id }
  end

  describe "#all" do
    it "puts the spike first, then the fill by the recent visitors, and then the date" do
      # a5 is much above its own usual traffic. a6 is popular but it agrees with its baseline. The
      # others have no traffic, and the newest of them is first.
      expect(ids).to eq(%w[a5 a6 a1 a2 a3 a4])
    end

    it "marks the spike as a trend and the steady article as fill" do
      expect(row("a5")[:status]).to eq(:trend)
      expect(row("a6")[:status]).to eq(:fill)
    end

    # ⚠️ MIN_VISITORS is what stops two visitors from a trend, whatever the baseline.
    it "keeps a very small count out of the trends" do
      noisy = article(id: "n1", slug: "noisy", published_at: "2023-11-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return(corpus + [ noisy ])
      stub_plausible(series: series.merge(noisy.path => daily(0 => described_class::MIN_VISITORS - 1)))

      expect(row("n1")[:status]).to eq(:fill)
      expect(ids.first(3)).to eq(%w[a5 a6 n1])
    end

    # The short window sees two visitors, which is below MIN_VISITORS, and the long window sees a
    # week at a rate far above the baseline.
    it "finds a ramp in the long window that the short window cannot see" do
      ramp = article(id: "r1", slug: "ramp", published_at: "2023-11-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return(corpus + [ ramp ])
      stub_plausible(series: series.merge(ramp.path => daily((0..6).to_h { |ago| [ ago, 1 ] })))

      windows = row("r1")[:windows]

      expect(windows[2][:surprise]).to be_nil
      expect(windows[7][:surprise]).to be >= described_class::SIGNIFICANCE
      expect(row("r1")[:status]).to eq(:trend)
    end

    # ⚠️ A new article has no baseline, thus its expected rate has no meaning. Its launch traffic
    # is not a trend.
    it "does not make a trend of a new article" do
      fresh = article(id: "f1", slug: "fresh", published_at: "2024-06-10T10:00:00Z")
      allow(articles_service).to receive(:list).and_return(corpus + [ fresh ])
      stub_plausible(series: series.merge(fresh.path => daily(0 => 20, 1 => 20)))

      expect(row("f1")[:status]).to eq(:fill)
      expect(ids.first).to eq("a5")
    end

    # ⚠️ The home page lists the newest Articles as "Recent Articles" directly above the widget.
    it "excludes the newest articles from the list" do
      stub_const("TrendingArticles::RECENT_EXCLUDED", 2)

      expect(ids).to eq(%w[a5 a6 a3 a4])
      expect(service.evaluate.select { |r| r[:status] == :recent }.map { |r| r[:article].sys.id }).to eq(%w[a1 a2])
    end

    # ⚠️ The popularity of all time comes before the date. Thus the fill shows the articles that
    # people read the most, and the widget is not a copy of the list of new posts on the home page.
    it "orders the fill by the recent visitors, then the popularity of all time, then the date" do
      stub_plausible(
        series: series.merge(art_april.path => daily(20 => 5), art_march.path => daily(40 => 9)),
        all_time: { art_march.path => 900, art_february.path => 400 }
      )

      expect(ids).to eq(%w[a5 a6 a2 a3 a4 a1])
    end

    it "falls back to the popularity of all time when the series is not available" do
      stub_plausible(series: nil, all_time: { art_march.path => 900, art_april.path => 400 })

      expect(ids).to eq(%w[a3 a2 a1 a4 a5 a6])
    end

    # The date is the last key, thus the order is always the same. sort_by is not stable.
    it "falls back to the date when nothing has traffic at all" do
      stub_plausible(series: {})

      expect(ids).to eq(%w[a1 a2 a3 a4 a5 a6])
    end

    it "excludes drafts and Shorts" do
      expect(ids).not_to include("s1", "d1")
    end

    it "returns an empty list when there are no candidates" do
      allow(articles_service).to receive(:list).and_return([])
      expect(service.all(count: 4)).to eq([])
    end

    it "respects the requested count" do
      expect(service.all(count: 1).size).to eq(1)
    end

    # ⚠️ The rescue is for each article. One bad date made the full widget empty for a full hour.
    it "omits an article with a malformed publish date and keeps the others" do
      bad = article(id: "x1", slug: "bad", published_at: "2024-01-01T10:00:00Z")
      allow(bad).to receive(:published_at).and_return("not-a-date")
      allow(articles_service).to receive(:list).and_return(corpus + [ bad ])

      expect(ids).to eq(%w[a5 a6 a1 a2 a3 a4])
    end

    it "matches the Plausible rows by the /YYYY/MM/DD/slug/ path of the article" do
      expect(art_spiking.path).to eq("/2024/01/15/spiking/")
      expect(ids.first).to eq("a5")
    end
  end

  describe "caching" do
    it "computes the ranking once per clock hour and reuses it across variants" do
      store = {}
      allow($redis).to receive(:get) { |key| store[key] }
      allow($redis).to receive(:setex) { |key, _ttl, value| store[key] = value }

      service.all(count: 4)
      service.all(count: 4)
      service.all(count: 10)

      # The series and Articles#list each run one time for the hour, for each call.
      expect(plausible_service).to have_received(:daily_visitors_by_path).once
      expect(articles_service).to have_received(:list).once
    end

    it "recomputes when the clock rolls to a new hour" do
      store = {}
      allow($redis).to receive(:get) { |key| store[key] }
      allow($redis).to receive(:setex) { |key, _ttl, value| store[key] = value }

      service.all(count: 4)
      travel_to(now + 1.hour)
      service.all(count: 4)

      expect(plausible_service).to have_received(:daily_visitors_by_path).twice
    end
  end
end
