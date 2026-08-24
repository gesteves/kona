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

  # A fixed "now", thus the moving window and the cache key are always the same.
  let(:now) { Time.utc(2024, 6, 15, 12, 0, 0) }

  # a1 to a4 have no recent traffic, thus they go in the group that the date orders. a5 has a surge:
  # a small recent count on a very small baseline. a6 is always popular: it has much traffic, but
  # that traffic agrees with its own high baseline. The app published a5 and a6 long before the start
  # of the baseline window, thus they have a full baseline.
  let(:art_newest)   { article(id: "a1", slug: "newest",   published_at: "2024-05-30T10:00:00Z") }
  let(:art_april)    { article(id: "a2", slug: "april",    published_at: "2024-04-01T10:00:00Z") }
  let(:art_march)    { article(id: "a3", slug: "march",    published_at: "2024-03-01T10:00:00Z") }
  let(:art_february) { article(id: "a4", slug: "february", published_at: "2024-02-01T10:00:00Z") }
  let(:art_spiking)  { article(id: "a5", slug: "spiking",  published_at: "2024-01-15T10:00:00Z") }
  let(:art_steady)   { article(id: "a6", slug: "steady",   published_at: "2024-01-01T10:00:00Z") }
  let(:art_short)    { article(id: "s1", slug: "short",    published_at: "2024-05-01T10:00:00Z", entry_type: "Short") }
  let(:art_draft)    { article(id: "d1", slug: "draft",    published_at: "2024-05-02T10:00:00Z", draft: true) }

  let(:corpus) { [ art_newest, art_april, art_march, art_february, art_spiking, art_steady, art_short, art_draft ] }

  # a5: 15 recent views, which is above the minimum, on a very small baseline. That is a large
  # surge.
  # a6: 72 recent views on a large baseline. That is a high volume, but the surge is close to 1.
  let(:recent) { { art_spiking.path => 15, art_steady.path => 72 } }
  let(:baseline) { { art_spiking.path => 30, art_steady.path => 2000 } }

  # The visitors of all time. They order the group with a score of 0.
  let(:all_time) { {} }

  let(:articles_service) { instance_double(Articles, list: corpus) }
  let(:plausible_service) { instance_double(Plausible) }
  subject(:service) { described_class.new(articles: articles_service, plausible: plausible_service) }

  before { travel_to(now) }
  after { travel_back }

  before do
    stub_plausible(recent: recent, baseline: baseline, all_time: all_time)
    # cached_json puts the list in the cache. This stubs Redis, thus the suite needs no Redis and
    # each example is separate.
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  # The recent window and the baseline are two { path => visitors } lookups over two date ranges.
  # The length of the range selects the answer: the recent range is short, and the baseline range is
  # approximately one month.
  def stub_plausible(recent:, baseline:, all_time: {})
    allow(plausible_service).to receive(:entry_visitors_by_path) do |**kwargs|
      first, last = kwargs[:date_range]
      span_hours = (Time.parse(last) - Time.parse(first)) / 3600.0
      span_hours <= (described_class::RECENT_WINDOW_HOURS + 1) ? recent : baseline
    end

    allow(plausible_service).to receive(:totals_by_path)
      .and_return(all_time.transform_values { |visitors| { visitors: visitors, pageviews: visitors } })
  end

  describe "#all" do
    it "ranks the surging article ahead of a steadily-popular one, then the rest by recency" do
      ids = service.all(count: 10).map { |a| a.sys.id }
      # a5 is hot against its own usual traffic. a6 is popular but it agrees with its baseline. The
      # other articles have no traffic and the newest is first, and a1 is the newest.
      expect(ids).to eq(%w[a5 a6 a1 a2 a3 a4])
    end

    it "ranks a small surge over its own low baseline above the same recent volume on a high baseline" do
      low  = article(id: "l1", slug: "low",  published_at: "2024-01-01T10:00:00Z")
      high = article(id: "h1", slug: "high", published_at: "2024-01-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return([ low, high ])
      # The two have the same recent volume, but `low` is much above its own usual traffic and
      # `high` is below its own.
      stub_plausible(
        recent: { low.path => 20, high.path => 20 },
        baseline: { low.path => 20, high.path => 4000 }
      )
      expect(service.all(count: 2).map { |a| a.sys.id }).to eq(%w[l1 h1])
    end

    it "excludes drafts and Shorts" do
      ids = service.all(count: 10).map { |a| a.sys.id }
      expect(ids).not_to include("s1", "d1")
    end

    # ⚠️ This is what the prior on both sides of the ratio does. 3 visitors on a baseline of zero
    # gave a surge of 3 with the prior on the divisor alone, and that looked the same as a true
    # surge. Now it gives a modest score below both true surges.
    it "keeps a very small count below a true surge" do
      noisy = article(id: "n1", slug: "noisy", published_at: "2023-11-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return(corpus + [ noisy ])
      stub_plausible(recent: recent.merge(noisy.path => 3), baseline: baseline)

      ids = service.all(count: 10).map { |a| a.sys.id }

      expect(ids.first(3)).to eq(%w[a5 a6 n1])
      expect(ids.index("n1")).to be > ids.index("a5")
    end

    # The floor is a percentile of the articles that got any traffic. Thus it goes up when many
    # articles have traffic, and no person tunes a number when the traffic of the site changes.
    it "removes an article below the percentile when many articles have traffic" do
      busy = (1..8).map { |i| article(id: "b#{i}", slug: "busy#{i}", published_at: "2024-01-0#{i}T10:00:00Z") }
      quiet = article(id: "q1", slug: "quiet", published_at: "2023-12-01T10:00:00Z")
      allow(articles_service).to receive(:list).and_return(busy + [ quiet ])
      # Each busy article has 40 visitors, thus the floor is 40. The quiet one has 3.
      stub_plausible(
        recent: busy.to_h { |a| [ a.path, 40 ] }.merge(quiet.path => 3),
        baseline: {}
      )

      ids = service.all(count: 10).map { |a| a.sys.id }

      expect(ids.last).to eq("q1")
    end

    # ⚠️ The fallback is the popularity of all time, and not the date. The widget renders on the
    # home page, which already lists the new posts. Thus a fallback by date made it a copy of that
    # list.
    it "falls back to the popularity of all time when there is no recent traffic" do
      stub_plausible(recent: {}, baseline: {}, all_time: { art_march.path => 900, art_february.path => 400 })

      ids = service.all(count: 10).map { |a| a.sys.id }

      expect(ids).to eq(%w[a3 a4 a1 a2 a5 a6])
    end

    # The date is the last key, thus the order is always the same. sort_by is not stable.
    it "falls back to the date when nothing has traffic at all" do
      stub_plausible(recent: {}, baseline: {})

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

    # ⚠️ The rescue is for each article. One bad date made the full widget empty for a full hour.
    it "omits an article with a malformed publish date and keeps the others" do
      bad = article(id: "x1", slug: "bad", published_at: "2024-01-01T10:00:00Z")
      allow(bad).to receive(:published_at).and_return("not-a-date")
      allow(articles_service).to receive(:list).and_return(corpus + [ bad ])

      ids = service.all(count: 10).map { |a| a.sys.id }

      expect(ids).to eq(%w[a5 a6 a1 a2 a3 a4])
    end

    it "matches the Plausible rows by the /YYYY/MM/DD/slug/ path of the article" do
      expect(art_spiking.path).to eq("/2024/01/15/spiking/")
      expect(service.all(count: 10).map { |a| a.sys.id }).to include("a5")
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

      # rank runs one time for the hour: the two entry-page queries, for the recent window and for
      # the baseline, and Articles#list each run one time, for each call.
      expect(plausible_service).to have_received(:entry_visitors_by_path).twice
      expect(articles_service).to have_received(:list).once
    end

    it "recomputes when the clock rolls to a new hour" do
      store = {}
      allow($redis).to receive(:get) { |key| store[key] }
      allow($redis).to receive(:setex) { |key, _ttl, value| store[key] = value }

      service.all(count: 4)
      travel_to(now + 1.hour)
      service.all(count: 4)

      # A new hour gives a new cache key, thus the code calculates again and does two more
      # entry-page queries.
      expect(plausible_service).to have_received(:entry_visitors_by_path).exactly(4).times
    end
  end
end
