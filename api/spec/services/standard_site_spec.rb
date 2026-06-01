require "rails_helper"

describe StandardSite do
  subject(:client) { described_class.new }

  let(:publication_uri) { "at://did:plc:abc123/site.standard.publication/self" }

  # A new instance has no session, so the pure record builders never hit the
  # network (upload_image_blob short-circuits when there's no access token).
  let(:site) do
    {
      "title" => "Given to Tri",
      "meta_description" => "A triathlon training & racing blog.",
      "logo" => { "url" => "//images.ctfassets.net/x/y/z/avatar.png", "content_type" => "image/png" }
    }
  end

  let(:post) do
    {
      "sys" => { "id" => "6L1asJJq4umcGEvD0hfqxE" },
      "title" => "Ironman updates their competition rules for 2026",
      "slug" => "ironman-competition-rules-2026",
      "summary" => nil,
      "intro" => "Some **bold** intro with a [link](https://example.com).",
      "body" => "The body of the post.",
      "entry_type" => "Short",
      "draft" => false,
      "published_at" => "2026-02-24T15:00:00.000-07:00",
      "updated_at" => "2026-02-24T22:07:58.616Z",
      "path" => "/2026/02/24/ironman-competition-rules-2026/",
      "contentful_metadata" => { "tags" => [{ "id" => "ironman", "name" => "Ironman" }, { "id" => "news", "name" => "News" }] }
    }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SITE_URL").and_return("https://www.giventotri.com")
  end

  describe "#build_publication_record" do
    subject(:record) { client.build_publication_record(site) }

    it "sets the lexicon type and the discovery preference" do
      expect(record["$type"]).to eq("site.standard.publication")
      expect(record["preferences"]).to eq("showInDiscover" => true)
    end

    it "uses the production root URL without a trailing slash" do
      expect(record["url"]).to eq("https://www.giventotri.com")
    end

    it "carries the name and a plain-text description" do
      expect(record["name"]).to eq("Given to Tri")
      expect(record["description"]).to eq("A triathlon training & racing blog.")
    end

    it "omits the icon when no blob is supplied" do
      expect(record).not_to have_key("icon")
    end

    it "includes the icon when a blob is supplied" do
      blob = { "$type" => "blob", "ref" => { "$link" => "bafy" } }
      record = client.build_publication_record(site, icon: blob)
      expect(record["icon"]).to eq(blob)
    end
  end

  describe "#build_document_record" do
    subject(:record) { client.build_document_record(post, publication_uri) }

    it "sets the lexicon type and points at the publication" do
      expect(record["$type"]).to eq("site.standard.document")
      expect(record["site"]).to eq(publication_uri)
    end

    it "normalizes the path to the canonical page URL (trailing slash kept)" do
      expect(record["path"]).to eq("/2026/02/24/ironman-competition-rules-2026/")
    end

    it "emits RFC3339 UTC timestamps" do
      expect(record["publishedAt"]).to eq("2026-02-24T22:00:00.000Z")
      expect(record["updatedAt"]).to eq("2026-02-24T22:07:58.616Z")
    end

    it "derives a plain-text description from the intro when no summary is set" do
      expect(record["description"]).to eq("Some bold intro with a link.")
    end

    it "strips markdown from the textContent" do
      expect(record["textContent"]).to eq("Some bold intro with a link. The body of the post.")
    end

    it "maps tag names without hashtags" do
      expect(record["tags"]).to eq(%w[Ironman News])
    end

    it "omits the cover image when no blob is supplied" do
      expect(record).not_to have_key("coverImage")
    end

    it "includes the cover image when a blob is supplied" do
      blob = { "$type" => "blob", "ref" => { "$link" => "bafy" } }
      record = client.build_document_record(post, publication_uri, cover_image: blob)
      expect(record["coverImage"]).to eq(blob)
    end

    it "prefers an explicit summary over the intro" do
      record = client.build_document_record(post.merge("summary" => "A short summary."), publication_uri)
      expect(record["description"]).to eq("A short summary.")
    end
  end

  describe "#publishable_posts" do
    let(:posts) do
      [
        post,
        post.merge("slug" => "a-draft", "draft" => true),
        post.merge("slug" => "a-page", "entry_type" => "Page"),
        post.merge("slug" => "an-article", "entry_type" => "Article")
      ]
    end

    it "keeps only non-draft articles and shorts" do
      slugs = client.publishable_posts(posts).map { |a| a["slug"] }
      expect(slugs).to contain_exactly("ironman-competition-rules-2026", "an-article")
    end
  end

  describe "#rkeys_to_prune" do
    it "returns existing rkeys that are not in the current set" do
      expect(client.rkeys_to_prune(%w[a b c], %w[b])).to eq(%w[a c])
    end

    it "returns nothing when every existing record is still current" do
      expect(client.rkeys_to_prune(%w[a b], %w[a b c])).to eq([])
    end

    it "handles empty inputs" do
      expect(client.rkeys_to_prune([], %w[a])).to eq([])
    end
  end

  describe "#document_fingerprint" do
    subject(:fingerprint) { client.document_fingerprint(post, publication_uri) }

    it "is stable for identical posts" do
      expect(fingerprint).to eq(client.document_fingerprint(post.dup, publication_uri))
    end

    it "changes when the publication URI changes" do
      other = client.document_fingerprint(post, "at://did:plc:other/site.standard.publication/self")
      expect(fingerprint).not_to eq(other)
    end

    {
      "title" => "A different title",
      "updated_at" => "2026-03-01T00:00:00.000Z",
      "body" => "A completely different body."
    }.each do |field, value|
      it "changes when #{field} changes" do
        expect(fingerprint).not_to eq(client.document_fingerprint(post.merge(field => value), publication_uri))
      end
    end

    it "changes when a tag changes" do
      changed = post.merge("contentful_metadata" => { "tags" => [{ "id" => "racing", "name" => "Racing" }] })
      expect(fingerprint).not_to eq(client.document_fingerprint(changed, publication_uri))
    end

    it "changes when the cover image source changes" do
      changed = post.merge("cover_image" => { "url" => "//images.ctfassets.net/a/b/c/new.jpg", "content_type" => "image/jpeg" })
      expect(fingerprint).not_to eq(client.document_fingerprint(changed, publication_uri))
    end
  end

  describe "#publication_fingerprint" do
    subject(:fingerprint) { client.publication_fingerprint(site) }

    it "is stable for identical site data" do
      expect(fingerprint).to eq(client.publication_fingerprint(site.dup))
    end

    {
      "title" => "A New Name",
      "meta_description" => "A different description."
    }.each do |field, value|
      it "changes when #{field} changes" do
        expect(fingerprint).not_to eq(client.publication_fingerprint(site.merge(field => value)))
      end
    end

    it "changes when the logo source changes" do
      changed = site.merge("logo" => { "url" => "//images.ctfassets.net/x/y/z/new-avatar.png", "content_type" => "image/png" })
      expect(fingerprint).not_to eq(client.publication_fingerprint(changed))
    end
  end
end
