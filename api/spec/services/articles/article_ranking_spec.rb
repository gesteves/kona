require "rails_helper"

RSpec.describe ArticleRanking do
  # A host with the state that the two rankings give the module.
  let(:host_class) do
    Class.new do
      include ArticleRanking
      public :candidates, :payload, :all_time_visitors

      def initialize(articles, plausible)
        @articles = articles
        @plausible = plausible
      end
    end
  end

  let(:articles) { instance_double(Articles, list: list) }
  let(:plausible) { instance_double(Plausible) }
  let(:host) { host_class.new(articles, plausible) }

  def article(**fields)
    DeepOstruct.wrap({ title: "T", summary: "S", slug: "t", path: "/2026/01/01/t/", published_at: "2026-01-01",
                       entry_type: "Article", draft: false, cover_image: nil, sys: { id: "a1" } }.merge(fields))
  end

  let(:list) do
    [
      article(sys: { id: "keep" }),
      article(sys: { id: "draft" }, draft: true),
      article(sys: { id: "short" }, entry_type: "Short"),
      article(sys: { id: "no-path" }, path: nil)
    ]
  end

  # ⚠️ The same filter as web: a draft, a Short, and an entry with no path are never candidates.
  it "keeps the published Articles that have a path" do
    expect(host.candidates.map { |a| a.sys.id }).to eq([ "keep" ])
  end

  it "makes a payload with each field that the card renders, and the cover image as a plain hash" do
    cover = { url: "https://images.ctfassets.net/s/a/t/p.jpg", width: 800, height: 600, content_type: "image/jpeg", sys: { id: "img", published_version: 3 } }

    payload = host.payload(article(cover_image: cover))

    expect(payload).to include(title: "T", slug: "t", path: "/2026/01/01/t/", entry_type: "Article", sys: { id: "a1" })
    expect(payload[:cover_image]).to eq(cover)
    expect(payload.to_json).to be_a(String)
  end

  it "gives no cover image for an article whose image has no URL" do
    expect(host.payload(article(cover_image: { url: nil }))[:cover_image]).to be_nil
  end

  it "reads the visitors of all time by path, and counts 0 with no answer" do
    allow(plausible).to receive(:totals_by_path).with(date_range: "all").and_return("/a/" => { visitors: 5, pageviews: 9 })
    expect(host.all_time_visitors).to eq("/a/" => 5)
    expect(host.all_time_visitors["/none/"]).to eq(0)

    allow(plausible).to receive(:totals_by_path).and_return(nil)
    expect(host.all_time_visitors).to eq({})
  end
end
