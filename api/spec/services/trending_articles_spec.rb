require "rails_helper"

RSpec.describe TrendingArticles do
  # Builds a decorated article the way Articles#list returns it.
  def article(id:, slug:, published_at:, title: "Title", summary: "Summary.", entry_type: "Article", draft: false)
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: title, summary: summary, slug: slug, published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, sys: { id: id }
    )
  end

  # a1–a4 are the four most recent (the "recent" set); a5 (spiking) and a6 (steady) are older.
  let(:art_newest)   { article(id: "a1", slug: "newest",   published_at: "2024-12-30T10:00:00Z") }
  let(:art_april)    { article(id: "a2", slug: "april",    published_at: "2024-04-01T10:00:00Z") }
  let(:art_march)    { article(id: "a3", slug: "march",    published_at: "2024-03-01T10:00:00Z") }
  let(:art_february) { article(id: "a4", slug: "february", published_at: "2024-02-01T10:00:00Z") }
  let(:art_spiking)  { article(id: "a5", slug: "spiking",  published_at: "2024-01-01T10:00:00Z") }
  let(:art_steady)   { article(id: "a6", slug: "steady",   published_at: "2023-12-01T10:00:00Z") }
  let(:art_short)    { article(id: "s1", slug: "short",    published_at: "2024-06-01T10:00:00Z", entry_type: "Short") }
  let(:art_draft)    { article(id: "d1", slug: "draft",    published_at: "2024-05-01T10:00:00Z", draft: true) }

  let(:corpus) { [art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short, art_draft] }

  # Daily series keyed by path. The spiking article has a low baseline with a big recent surge; the
  # steady article has flat, moderate traffic. Everyone else has none.
  let(:series) do
    {
      art_spiking.path => spike_series(base: 2, spike: 40),
      art_steady.path  => flat_series(rate: 5)
    }
  end

  let(:articles_service) { instance_double(Articles, list: corpus) }
  let(:plausible_service) { instance_double(Plausible) }
  subject(:service) { described_class.new(articles: articles_service, plausible: plausible_service) }

  before do
    stub_series(series)
    # The ranking is cached via cached_json; stub Redis so the suite stays Redis-free and isolated.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  # The last `WINDOW_DAYS` calendar dates, most-recent first.
  def days_back(count)
    (0...count).map { |i| Date.current - i }
  end

  # Flat baseline with `spike` pageviews on the last RECENT_DAYS days, `base` before that.
  def spike_series(base:, spike:, days: described_class::WINDOW_DAYS)
    days_back(days).each_with_index.to_h { |day, i| [day, i < described_class::RECENT_DAYS ? spike : base] }
  end

  def flat_series(rate:, days: described_class::WINDOW_DAYS)
    days_back(days).to_h { |day| [day, rate] }
  end

  # Stubs Plausible#query to return time:day rows ({ dimensions: [path, "YYYY-MM-DD"], metrics: [pv] }).
  def stub_series(series_by_path)
    allow(plausible_service).to receive(:query) do
      rows = series_by_path.flat_map do |path, by_day|
        by_day.map { |day, pv| { dimensions: [path, day.iso8601], metrics: [pv] } }
      end
      { results: rows }
    end
  end

  it "ranks the spiking article ahead of steady ones, excluding the recent set" do
    ids = service.non_recent(count: 4).map { |a| a.sys.id }
    expect(ids).to eq(%w[a5 a6]) # a1–a4 are the four most recent and are dropped
  end

  it "excludes drafts and Shorts" do
    ids = service.non_recent(count: 4).map { |a| a.sys.id }
    expect(ids).not_to include("s1", "d1")
  end

  it "scores articles with no recent activity at 0, so spiking wins" do
    expect(service.non_recent(count: 4).first.sys.id).to eq("a5")
  end

  it "ignores low-volume noise below the eligibility floor" do
    # A 0→2 'spike' (6 views total, below MIN_WINDOW_PAGEVIEWS) would score a z≈2 without the floor
    # and leapfrog the steady article; the floor zeroes it, so it sinks below steady to recency order.
    noisy = article(id: "n1", slug: "noisy", published_at: "2023-11-01T10:00:00Z")
    allow(articles_service).to receive(:list).and_return(corpus + [noisy])
    stub_series(series.merge(noisy.path => spike_series(base: 0, spike: 2)))
    ids = service.non_recent(count: 4).map { |a| a.sys.id }
    expect(ids).to eq(%w[a5 a6 n1]) # spike wins, steady second, noise scored 0 → last (recency)
  end

  it "falls back to recency order when analytics are unavailable" do
    stub_series({}) # no pageviews for anyone → all scores 0
    ids = service.non_recent(count: 4).map { |a| a.sys.id }
    expect(ids).to eq(%w[a5 a6])
  end

  it "returns an empty list when there are no candidates" do
    allow(articles_service).to receive(:list).and_return([])
    expect(service.non_recent(count: 4)).to eq([])
  end

  it "respects the requested count" do
    expect(service.non_recent(count: 1).size).to eq(1)
  end

  it "degrades to an empty list instead of raising on a malformed publish date" do
    bad = article(id: "x1", slug: "bad", published_at: "2024-01-01T10:00:00Z")
    allow(bad).to receive(:published_at).and_return("not-a-date")
    allow(articles_service).to receive(:list).and_return(corpus + [bad])
    expect(service.non_recent(count: 4)).to eq([])
  end

  it "matches Plausible pageviews by the article's /YYYY/MM/DD/slug/ path" do
    expect(art_spiking.path).to eq("/2024/01/01/spiking/")
    # spiking only surfaces because its daily series is keyed by that exact path
    expect(service.non_recent(count: 4).map { |a| a.sys.id }).to include("a5")
  end
end
