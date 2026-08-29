require "rails_helper"

RSpec.describe SharePresenter do
  def article(overrides = {})
    DeepOstruct.wrap({
      title: "Ironman Canada", summary: "A long day in Penticton.", slug: "ironman-canada",
      draft: false, published_at: "2026-07-12T00:00:00Z", entry_type: "Article",
      path: "/2026/07/12/ironman-canada/", sys: { id: "entry-1" }
    }.merge(overrides))
  end

  def network(key: "bluesky", name: "Bluesky", account: "@me.bsky.social", connected: true)
    described_class::Network.new(key: key, name: name, account: account, connected: connected)
  end

  subject(:presenter) do
    described_class.new(articles: articles, networks: [ network ], site_url: "https://example.test/")
  end

  let(:articles) { [ article ] }

  describe "the article list" do
    it "makes the absolute URL from the canonical path" do
      expect(presenter.articles.first.url).to eq("https://example.test/2026/07/12/ironman-canada/")
    end

    it "removes a draft and an entry with no path" do
      articles.push(article(title: "Draft", draft: true, path: nil, sys: { id: "entry-2" }))
      articles.push(article(title: "No path", path: nil, sys: { id: "entry-3" }))

      expect(presenter.articles.map(&:title)).to eq([ "Ironman Canada" ])
    end

    # ⚠️ A Short is a published entry, and the owner can share one. This is why the code here does
    # not reuse ArticleRanking#candidates, which removes each Short.
    it "keeps a Short" do
      articles.push(article(title: "A note", entry_type: "Short", slug: "a-note",
                            path: "/2026/08/01/a-note/", sys: { id: "entry-2" }))

      expect(presenter.articles.map(&:entry_type)).to include("Short")
    end

    it "puts the newest entry first" do
      articles.push(article(title: "Newer", published_at: "2026-08-01T00:00:00Z",
                            path: "/2026/08/01/newer/", sys: { id: "entry-2" }))

      expect(presenter.articles.map(&:title)).to eq([ "Newer", "Ironman Canada" ])
    end

    # Articles#list gives an empty array after a failure at Contentful. The page then renders a
    # callout and does not raise.
    it "is empty when the list is empty" do
      expect(described_class.new(articles: [], networks: [], site_url: "https://example.test"))
        .to be_empty
    end
  end

  describe "a network row" do
    it "names the account when one is connected" do
      expect(network.account_line).to eq("Posts as @me.bsky.social.")
    end

    it "says only Connected when the service gives no name" do
      expect(network(account: nil).account_line).to eq("Connected.")
    end

    it "answers connected?" do
      expect(network(connected: false)).not_to be_connected
    end
  end

  describe "the limits" do
    # 300 is the Bluesky limit, which is the shortest of the three, and one body goes to all of
    # them. ⚠️ The view writes both numbers into the markup, and share_controller.js reads them
    # there.
    it "warns below the limit" do
      expect(described_class::WARN_AT).to be < described_class::BODY_LIMIT
      expect(described_class::BODY_LIMIT).to eq(300)
    end
  end
end
