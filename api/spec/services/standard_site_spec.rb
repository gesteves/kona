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
      "contentful_metadata" => { "tags" => [ { "id" => "ironman", "name" => "Ironman" }, { "id" => "news", "name" => "News" } ] }
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

    it "carries a basic theme with all four required colors" do
      expect(record["basicTheme"]).to include("$type" => "site.standard.theme.basic")
      expect(record["basicTheme"].keys).to contain_exactly(
        "$type", "background", "foreground", "accent", "accentForeground"
      )
    end

    # Pinned so a palette edit is a deliberate diff, not a silent one. These mirror web's
    # light-mode tokens in web/source/stylesheets/base/_props.scss.
    {
      "background" => [ 255, 255, 255 ],
      "foreground" => [ 41, 41, 41 ],
      "accent" => [ 191, 2, 34 ],
      "accentForeground" => [ 250, 250, 250 ]
    }.each do |role, (r, g, b)|
      it "renders #{role} as rgb(#{r}, #{g}, #{b})" do
        expect(record.dig("basicTheme", role)).to eq(
          "$type" => "site.standard.theme.color#rgb", "r" => r, "g" => g, "b" => b
        )
      end
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

  describe "the publication record key" do
    it "is a valid 13-character TID, not the literal 'self'" do
      expect(StandardSite::PUBLICATION_RKEY).to eq("73k3tsvpuwib6")
      expect(StandardSite::PUBLICATION_RKEY).to match(/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/)
    end

    it "builds the publication URI from the TID" do
      expect(StandardSite.publication_uri("did:plc:abc")).to eq("at://did:plc:abc/site.standard.publication/73k3tsvpuwib6")
    end
  end

  describe "#document_rkey" do
    # The exact TID for the fixture sys.id is asserted here (and in web's matching spec)
    # so the two apps can never drift: the <link> AT URI must equal the published record.
    it "derives a valid 13-character TID from the Contentful sys.id" do
      rkey = client.document_rkey("6L1asJJq4umcGEvD0hfqxE")
      expect(rkey).to eq("3446ygrm3x4bk")
      expect(rkey).to match(/\A[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}\z/)
    end

    it "is stable for the same sys.id and distinct for different ones" do
      expect(client.document_rkey("6navMJAmcxXgFwFr0KxgOz")).to eq(client.document_rkey("6navMJAmcxXgFwFr0KxgOz"))
      expect(client.document_rkey("6navMJAmcxXgFwFr0KxgOz")).not_to eq(client.document_rkey("6L1asJJq4umcGEvD0hfqxE"))
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
      changed = post.merge("contentful_metadata" => { "tags" => [ { "id" => "racing", "name" => "Racing" } ] })
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

  describe "#article_tags (taxonomy concepts)" do
    def raw(*concept_ids)
      { contentfulMetadata: { concepts: concept_ids.map { |id| { id: id } } } }
    end

    it "resolves concept ids to names via TaxonomyConcepts, in order" do
      allow_any_instance_of(TaxonomyConcepts).to receive(:names).and_return(
        "ironman-703" => "Ironman 70.3", "ironman-703-coeur-dalene" => "Ironman 70.3 Coeur d’Alene"
      )
      expect(client.send(:article_tags, raw("ironman-703", "ironman-703-coeur-dalene"))).to eq([
        { "id" => "ironman-703", "name" => "Ironman 70.3" },
        { "id" => "ironman-703-coeur-dalene", "name" => "Ironman 70.3 Coeur d’Alene" }
      ])
    end

    it "drops concept ids the taxonomy doesn't know" do
      allow_any_instance_of(TaxonomyConcepts).to receive(:names).and_return("known" => "Known")
      expect(client.send(:article_tags, raw("known", "missing"))).to eq([ { "id" => "known", "name" => "Known" } ])
    end

    it "returns [] when the article has no concepts" do
      expect(client.send(:article_tags, raw)).to eq([])
    end

    it "returns [] when no concept name resolves" do
      allow_any_instance_of(TaxonomyConcepts).to receive(:names).and_return({})
      expect(client.send(:article_tags, raw("ironman-703"))).to eq([])
    end
  end

  describe "#backfill" do
    # A raw (symbol-keyed) CDA article item, as fetch_all_articles returns it.
    # publishedVersion present ⇒ not a draft; body present ⇒ Article ⇒ publishable.
    def raw_article(id, published_version: 3)
      {
        sys: { id: id, publishedVersion: published_version, publishedAt: "2026-02-24T22:07:58.616Z",
               firstPublishedAt: "2026-02-24T15:00:00.000-07:00" },
        title: "Title #{id}", slug: "slug-#{id}", summary: nil, intro: "Intro", body: "Body",
        coverImage: nil, contentfulMetadata: { concepts: [] }
      }
    end

    before do
      # Stub the network boundary; backfill's orchestration + enqueuing is what's under test.
      allow(client).to receive(:valid_credentials?).and_return(true)
      allow(client).to receive(:create_session).and_return(true)
      allow(client).to receive(:fetch_site).and_return(site)
      allow(client).to receive(:do_sync_publication)
      allow(client).to receive(:prune_legacy_publication)
      allow(client).to receive(:prune_documents).and_return(0)
    end

    it "enqueues one document sync job per publishable post (skipping drafts) and still prunes" do
      allow(client).to receive(:fetch_all_articles).and_return([
        raw_article("AAA111"), raw_article("BBB222"),
        raw_article("DRAFT0", published_version: nil) # draft ⇒ excluded
      ])

      expect(client).to receive(:prune_documents).with(array_including(kind_of(String))).and_return(0)
      client.backfill

      expect(StandardSiteSyncJob).to have_enqueued_sidekiq_job("sync_document", "AAA111")
      expect(StandardSiteSyncJob).to have_enqueued_sidekiq_job("sync_document", "BBB222")
      expect(StandardSiteSyncJob.jobs.size).to eq(2)
    end

    it "does not prune (or enqueue) when the article fetch fails" do
      allow(client).to receive(:fetch_all_articles).and_return(nil)
      expect(client).not_to receive(:prune_documents)

      client.backfill

      expect(StandardSiteSyncJob.jobs).to be_empty
    end
  end

  describe "#connect!" do
    let(:client) do
      described_class.new(credentials: BlueskyCredentials::Credentials.new(handle: "me.bsky.social", app_password: "pw", source: :admin))
    end
    let(:publication_fingerprint_key) do
      "standard_site:fingerprint:#{StandardSite::PUBLICATION_COLLECTION}:#{StandardSite::PUBLICATION_RKEY}"
    end

    def reset_keys = $redis.del(StandardSite::DID_CACHE_KEY, publication_fingerprint_key, BlueskyCredentials::REDIS_KEY)

    before { reset_keys }
    after { reset_keys }

    it "stores the credentials once a session opens" do
      allow(client).to receive(:create_session).and_return(true)

      expect(client.connect!).to be(true)
      expect(BlueskyCredentials.fetch.handle).to eq("me.bsky.social")
    end

    it "stores nothing when the session fails" do
      allow(client).to receive(:create_session).and_return(false)

      expect(client.connect!).to be(false)
      expect(BlueskyCredentials.stored?).to be(false)
    end

    it "stores nothing without both halves of a pair" do
      blank = described_class.new(
        credentials: BlueskyCredentials::Credentials.new(handle: "me.bsky.social", app_password: nil, source: :admin)
      )

      expect(blank.connect!).to be(false)
      expect(BlueskyCredentials.stored?).to be(false)
    end

    # ⚠️ Document fingerprints cover the publication's at:// URI, which carries the DID, so they
    # invalidate themselves when the account changes. The publication record's doesn't — a stale
    # one would report :unchanged forever and never sync to the new repo.
    it "drops the publication fingerprint when the account changed" do
      $redis.set(StandardSite::DID_CACHE_KEY, "did:plc:old")
      $redis.set(publication_fingerprint_key, "stale")
      allow(client).to receive(:create_session) do
        client.instance_variable_set(:@did, "did:plc:new")
        true
      end

      client.connect!

      expect($redis.get(publication_fingerprint_key)).to be_nil
    end

    it "keeps the publication fingerprint when reconnecting the same account" do
      $redis.set(StandardSite::DID_CACHE_KEY, "did:plc:same")
      $redis.set(publication_fingerprint_key, "current")
      allow(client).to receive(:create_session) do
        client.instance_variable_set(:@did, "did:plc:same")
        true
      end

      client.connect!

      expect($redis.get(publication_fingerprint_key)).to eq("current")
    end
  end

  describe "#disconnect!" do
    # ⚠️ The DID is public data, not a credential, and GET /api/standard-site feeds the
    # verification <link> tags on every page of the static site.
    it "forgets the credentials but leaves the cached DID alone" do
      BlueskyCredentials.store(handle: "me.bsky.social", app_password: "pw")
      $redis.set(StandardSite::DID_CACHE_KEY, "did:plc:abc")

      described_class.new.disconnect!

      expect(BlueskyCredentials.stored?).to be(false)
      expect($redis.get(StandardSite::DID_CACHE_KEY)).to eq("did:plc:abc")
    ensure
      $redis.del(StandardSite::DID_CACHE_KEY, BlueskyCredentials::REDIS_KEY)
    end
  end

  describe "deleting a document record" do
    let(:entry_id) { "6L1asJJq4umcGEvD0hfqxE" }
    let(:rkey) { client.document_rkey(entry_id) }

    before do
      allow(client).to receive(:valid_credentials?).and_return(true)
      allow(client).to receive(:create_session).and_return(true)
      allow(client).to receive(:forget_fingerprint)
    end

    # Every record key in both standard.site lexicons is a TID, so a Contentful sys.id can never
    # be one. Passing the raw id deletes a key that doesn't exist and reports success, leaving the
    # real record live on the PDS until the next backfill prunes it.
    it "addresses the record by its TID rkey, never the raw Contentful id" do
      expect(client).to receive(:delete_record).with(StandardSite::DOCUMENT_COLLECTION, rkey).and_return(true)

      client.delete_document(entry_id)
    end

    it "deletes by TID rkey when a published entry becomes unpublishable" do
      allow(client).to receive(:eligible?).and_return(true)
      allow(client).to receive(:fetch_article).and_return({ title: "Draft" })
      allow(client).to receive(:decorate_post).and_return({ "title" => "Draft" })
      allow(client).to receive(:publishable_posts).and_return([])
      expect(client).to receive(:delete_record).with(StandardSite::DOCUMENT_COLLECTION, rkey).and_return(true)

      expect(client.sync_document(entry_id)).to eq(:deleted)
    end

    # A swallowed failure would drop the fingerprint too, so nothing would ever re-detect the
    # orphaned record.
    it "raises (so Sidekiq retries) and keeps the fingerprint when the PDS rejects the delete" do
      allow(client).to receive(:delete_record).and_return(false)
      expect(client).not_to receive(:forget_fingerprint)

      expect { client.delete_document(entry_id) }.to raise_error(/could not delete document/)
    end
  end
end
