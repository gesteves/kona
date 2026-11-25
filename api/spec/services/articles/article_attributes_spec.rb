require "rails_helper"

RSpec.describe ArticleAttributes do
  describe ".path" do
    it "builds the dated permalink from the slug and publish date" do
      path = described_class.path(slug: "a-post", published_at: "2026-06-15T09:00:00Z")

      expect(path).to eq("/2026/06/15/a-post/")
    end

    # ⚠️ The date comes from the offset of the timestamp, and the code never changes it to UTC. An
    # article that a person publishes at 23:30 Pacific has a permalink for *January 1*. In UTC, that
    # permalink would move to January 2. A published permalink that moves is a link that does not
    # work, and its pageview count becomes zero, because Plausible matches on that path.
    it "reckons the date in the timestamp's own zone, not UTC" do
      path = described_class.path(slug: "late-post", published_at: "2026-01-01T23:30:00-08:00")

      expect(path).to eq("/2026/01/01/late-post/")
    end

    it "zero-pads the month and day" do
      expect(described_class.path(slug: "p", published_at: "2026-03-07T00:00:00Z")).to eq("/2026/03/07/p/")
    end

    it "is nil for a draft, a blank slug, or a missing publish date" do
      expect(described_class.path(slug: "p", published_at: "2026-06-15T09:00:00Z", draft: true)).to be_nil
      expect(described_class.path(slug: "", published_at: "2026-06-15T09:00:00Z")).to be_nil
      expect(described_class.path(slug: "p", published_at: nil)).to be_nil
    end

    # The static build writes the same path with an index.html at the end (refer to
    # Contentful#set_article_path of the web app), and url_for removes that part. If the two formats
    # become different, each card that the api renders points at a 404.
    it "matches the static build's permalink format" do
      published_at = "2026-06-15T09:00:00Z"
      published = DateTime.parse(published_at)
      web_path = "/#{published.strftime('%Y')}/#{published.strftime('%m')}/#{published.strftime('%d')}/a-post/index.html"

      expect(described_class.path(slug: "a-post", published_at: published_at))
        .to eq(web_path.delete_suffix("index.html"))
    end
  end

  describe ".derive" do
    def derive(**overrides)
      described_class.derive(**{
        slug: "a-post",
        published_version: 3,
        published: "2026-06-15T09:00:00Z",
        first_published_at: "2026-06-01T09:00:00Z"
      }.merge(overrides))
    end

    it "prefers the editorial publish date over sys.firstPublishedAt" do
      expect(derive[:published_at]).to eq("2026-06-15T09:00:00Z")
      expect(derive[:path]).to eq("/2026/06/15/a-post/")
    end

    it "falls back to sys.firstPublishedAt when no editorial date is set" do
      expect(derive(published: nil)[:published_at]).to eq("2026-06-01T09:00:00Z")
      expect(derive(published: "")[:published_at]).to eq("2026-06-01T09:00:00Z")
    end

    it "treats a blank publishedVersion as a draft, and gives it no path" do
      expect(derive(published_version: nil)).to include(draft: true, path: nil)
      expect(derive(published_version: "")).to include(draft: true, path: nil)
      expect(derive[:draft]).to be(false)
    end

    it "types an entry by whether it has a body" do
      expect(derive(body: "Some prose.")[:entry_type]).to eq("Article")
      expect(derive(body: nil)[:entry_type]).to eq("Short")
      expect(derive(body: "")[:entry_type]).to eq("Short")
    end

    it "returns no path when neither timestamp is present" do
      expect(derive(published: nil, first_published_at: nil)).to include(published_at: nil, path: nil)
    end
  end
end
