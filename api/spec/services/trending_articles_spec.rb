require "rails_helper"

RSpec.describe TrendingArticles do
  include ActiveSupport::Testing::TimeHelpers

  # Builds a decorated article the way Articles#list returns it.
  def article(id:, slug:, published_at:, title: "Title", summary: "Summary.", entry_type: "Article", draft: false)
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: title, summary: summary, slug: slug, published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, sys: { id: id }
    )
  end

  # Frozen "now" so the rolling window and cache key are deterministic.
  let(:now) { Time.utc(2024, 6, 15, 12, 0, 0) }

  # a1–a4 have no recent traffic (they fill the recency tail); a5 surges (a modest recent count on a
  # tiny baseline); a6 is steadily popular (lots of traffic, but in line with its own high baseline).
  # a5/a6 were published well before the baseline window starts, so they have a full baseline history.
  let(:art_newest)   { article(id: "a1", slug: "newest",   published_at: "2024-05-30T10:00:00Z") }
  let(:art_april)    { article(id: "a2", slug: "april",    published_at: "2024-04-01T10:00:00Z") }
  let(:art_march)    { article(id: "a3", slug: "march",    published_at: "2024-03-01T10:00:00Z") }
  let(:art_february) { article(id: "a4", slug: "february", published_at: "2024-02-01T10:00:00Z") }
  let(:art_spiking)  { article(id: "a5", slug: "spiking",  published_at: "2024-01-15T10:00:00Z") }
  let(:art_steady)   { article(id: "a6", slug: "steady",   published_at: "2024-01-01T10:00:00Z") }
  let(:art_short)    { article(id: "s1", slug: "short",    published_at: "2024-05-01T10:00:00Z", entry_type: "Short") }
  let(:art_draft)    { article(id: "d1", slug: "draft",    published_at: "2024-05-02T10:00:00Z", draft: true) }

  let(:corpus) { [art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short, art_draft] }

  # a5: 15 recent views (over the floor) on a tiny baseline → big surge.
  # a6: 72 recent views on a large baseline → high volume, but surge ≈ 1.
  let(:recent) { rows(art_spiking.path => 15, art_steady.path => 72) }
  let(:baseline) { rows(art_spiking.path => 30, art_steady.path => 2000) }

  let(:articles_service) { instance_double(Articles, list: corpus) }
  let(:plausible_service) { instance_double(Plausible) }
  subject(:service) { described_class.new(articles: articles_service, plausible: plausible_service) }

  before { travel_to(now) }
  after { travel_back }

  before do
    stub_plausible(recent: recent, baseline: baseline)
    # The ranking is cached via cached_json; stub Redis so the suite stays Redis-free and isolated.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  # { path => total_pageviews } → event:page rows.
  def rows(by_path)
    by_path.map { |path, total| { dimensions: [path], metrics: [total] } }
  end

  # The recent window and the baseline are two event:page queries over different date ranges; branch on
  # the range span (recent is short, baseline is ~a month) to answer each.
  def stub_plausible(recent:, baseline:)
    allow(plausible_service).to receive(:query) do |**kwargs|
      first, last = kwargs[:date_range]
      span_hours = (Time.parse(last) - Time.parse(first)) / 3600.0
      { results: span_hours <= (described_class::RECENT_WINDOW_HOURS + 1) ? recent : baseline }
    end
  end

  describe "#all" do
    it "ranks the surging article ahead of a steadily-popular one, then the rest by recency" do
      ids = service.all(count: 10).map { |a| a.sys.id }
      # a5 is hot relative to its own normal; a6 is popular but in line with its baseline; the
      # zero-traffic remainder follows newest-first (a1 is the newest).
      expect(ids).to eq(%w[a5 a6 a1 a2 a3 a4])
    end

    it "ranks a small surge over its own low baseline above the same recent volume on a high baseline" do
      low  = article(id: "l1", slug: "low",  published_at: "2024-01-01T10:00:00Z")
      high = article(id: "h1", slug: "high", published_at: "2024-01-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return([low, high])
      # Identical recent volume, but `low` is way above its own normal while `high` is below its.
      stub_plausible(
        recent: rows(low.path => 20, high.path => 20),
        baseline: rows(low.path => 20, high.path => 4000)
      )
      expect(service.all(count: 2).map { |a| a.sys.id }).to eq(%w[l1 h1])
    end

    it "excludes drafts and Shorts" do
      ids = service.all(count: 10).map { |a| a.sys.id }
      expect(ids).not_to include("s1", "d1")
    end

    it "ignores recent traffic below the eligibility floor" do
      # 3 recent views (< MIN_RECENT_PAGEVIEWS) on a zero baseline would surge hugely without the floor;
      # the floor zeroes it, so it sinks to recency order (oldest last).
      noisy = article(id: "n1", slug: "noisy", published_at: "2023-11-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return(corpus + [noisy])
      stub_plausible(recent: recent + rows(noisy.path => 3), baseline: baseline)
      ids = service.all(count: 10).map { |a| a.sys.id }
      expect(ids).to eq(%w[a5 a6 a1 a2 a3 a4 n1])
    end

    it "falls back to recency order when there's no recent traffic" do
      stub_plausible(recent: [], baseline: [])
      ids = service.all(count: 10).map { |a| a.sys.id }
      expect(ids).to eq(%w[a1 a2 a3 a4 a5 a6])
    end

    it "returns an empty list when there are no candidates" do
      allow(articles_service).to receive(:list).and_return([])
      expect(service.all(count: 4)).to eq([])
    end

    it "respects the requested count" do
      expect(service.all(count: 1).size).to eq(1)
    end

    it "degrades to an empty list instead of raising on a malformed publish date" do
      bad = article(id: "x1", slug: "bad", published_at: "2024-01-01T10:00:00Z")
      allow(bad).to receive(:published_at).and_return("not-a-date")
      allow(articles_service).to receive(:list).and_return(corpus + [bad])
      expect(service.all(count: 4)).to eq([])
    end

    it "matches Plausible pageviews by the article's /YYYY/MM/DD/slug/ path" do
      expect(art_spiking.path).to eq("/2024/01/15/spiking/")
      expect(service.all(count: 10).map { |a| a.sys.id }).to include("a5")
    end
  end

  describe "#excluding" do
    it "drops every article whose Contentful id is in the list" do
      ids = service.excluding(%w[a5 a6], count: 4).map { |a| a.sys.id }
      expect(ids).not_to include("a5", "a6")
      expect(ids).to eq(%w[a1 a2 a3 a4]) # the rest, in ranked (here recency) order
    end

    it "tolerates ids that aren't in the corpus" do
      ids = service.excluding(%w[nope], count: 4).map { |a| a.sys.id }
      expect(ids).to eq(service.all(count: 4).map { |a| a.sys.id })
    end

    it "still excludes drafts and Shorts" do
      ids = service.excluding(%w[a5], count: 10).map { |a| a.sys.id }
      expect(ids).not_to include("s1", "d1")
    end
  end

  describe "caching" do
    it "computes the ranking once per clock hour and reuses it across variants" do
      store = {}
      allow($redis).to receive(:get) { |key| store[key] }
      allow($redis).to receive(:setex) { |key, _ttl, value| store[key] = value }

      service.all(count: 4)
      service.excluding(%w[a5], count: 4)
      service.excluding(%w[garbage-id], count: 4)

      # rank runs once for the hour: the two Plausible queries (recent + baseline) and Articles#list
      # each fire exactly once, no matter the exclusion set.
      expect(plausible_service).to have_received(:query).twice
      expect(articles_service).to have_received(:list).once
    end

    it "recomputes when the clock rolls to a new hour" do
      store = {}
      allow($redis).to receive(:get) { |key| store[key] }
      allow($redis).to receive(:setex) { |key, _ttl, value| store[key] = value }

      service.all(count: 4)
      travel_to(now + 1.hour)
      service.all(count: 4)

      # A fresh hour → a fresh cache key → a second compute (two more Plausible queries).
      expect(plausible_service).to have_received(:query).exactly(4).times
    end
  end
end
