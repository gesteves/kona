require 'spec_helper'

# lib/data/contentful.rb requires graphql/contentful, which reads the live Contentful schema at
# load time. That needs a network and credentials, which CI does not have. Thus this file registers
# a replacement module and marks that file as loaded, and the require then does nothing. These
# specs cover only the transform methods, and never the fetch.
graphql_client_path = File.expand_path('../../../lib/data/graphql/contentful.rb', __dir__)
unless $LOADED_FEATURES.include?(graphql_client_path)
  module ContentfulClient
    Client = nil
    QUERIES = nil
  end
  $LOADED_FEATURES << graphql_client_path
end
require_relative '../../../lib/data/contentful'

RSpec.describe Contentful do
  # The initializer gets all the data from Contentful. allocate does not call it, thus the specs
  # can run the transform methods against a @content that this file makes.
  def importer(content = {})
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@content, { site: {} }.merge(content))
    end
  end

  def transform(method, item, *args)
    importer.send(method, item, *args)
  end

  describe '#set_entry_type' do
    it 'derives Article for entries with intro and body' do
      expect(transform(:set_entry_type, { intro: 'i', body: 'b' })[:entry_type]).to eq('Article')
    end

    it 'derives Short for entries with only an intro' do
      expect(transform(:set_entry_type, { intro: 'i', body: nil })[:entry_type]).to eq('Short')
    end

    it 'uses an explicit type when given' do
      expect(transform(:set_entry_type, { intro: 'i', body: 'b' }, 'Page')[:entry_type]).to eq('Page')
    end
  end

  describe '#set_draft_status' do
    it 'marks unpublished entries as drafts and hides them from search engines' do
      item = transform(:set_draft_status, { sys: { published_version: nil }, index_in_search_engines: true })
      expect(item[:draft]).to be(true)
      expect(item[:index_in_search_engines]).to be(false)
    end

    it 'leaves published entries alone' do
      item = transform(:set_draft_status, { sys: { published_version: 3 }, index_in_search_engines: true })
      expect(item[:draft]).to be(false)
      expect(item[:index_in_search_engines]).to be(true)
    end
  end

  describe '#set_timestamps' do
    it 'prefers the author-set publish date' do
      item = transform(:set_timestamps, { published: '2026-01-01', sys: { first_published_at: '2025-01-01', published_at: '2026-02-01' } })
      expect(item[:published_at]).to eq('2026-01-01')
      expect(item[:updated_at]).to eq('2026-02-01')
    end

    it 'falls back to the first publish date' do
      item = transform(:set_timestamps, { published: nil, sys: { first_published_at: '2025-01-01' } })
      expect(item[:published_at]).to eq('2025-01-01')
    end
  end

  describe 'paths and templates' do
    it 'gives published articles dated permalink paths' do
      item = transform(:set_article_path, { draft: false, published_at: '2026-06-15T09:00:00-06:00', slug: 'my-race' })
      expect(item[:path]).to eq('/2026/06/15/my-race/index.html')
    end

    it "dates the path in the timestamp's own zone, not UTC (pins permalink stability)" do
      # 22:30 on June 15 in -06:00 is June 16 in UTC. The permalink keeps the local date of the
      # publish. A change to UTC would move the URLs that exist.
      item = transform(:set_article_path, { draft: false, published_at: '2026-06-15T22:30:00-06:00', slug: 'my-race' })
      expect(item[:path]).to eq('/2026/06/15/my-race/index.html')
    end

    it 'gives drafts a stable id-based preview path in both collections' do
      article = transform(:set_article_path, { draft: true, sys: { id: 'abc' } })
      page = transform(:set_page_path, { draft: true, sys: { id: 'abc' } })
      expect(article[:path]).to eq('/id/abc/index.html')
      expect(page[:path]).to eq('/id/abc/index.html')
    end

    it 'routes the home page to the root and other pages to their slug' do
      expect(transform(:set_page_path, { draft: false, is_home_page: true })[:path]).to eq('/index.html')
      expect(transform(:set_page_path, { draft: false, slug: 'about' })[:path]).to eq('/about/index.html')
    end

    it 'picks the template by entry type' do
      expect(transform(:set_template, { entry_type: 'Article' })[:template]).to eq('/article.html')
      expect(transform(:set_template, { entry_type: 'Short' })[:template]).to eq('/short.html')
      expect(transform(:set_template, { entry_type: 'Page', is_home_page: true })[:template]).to eq('/home.html')
      expect(transform(:set_template, { entry_type: 'Page' })[:template]).to eq('/page.html')
    end
  end

  describe '#process_collection' do
    it 'derives fields and sorts newest-first' do
      articles = [
        { intro: 'i', body: 'b', slug: 'older', published: '2025-01-01', sys: { id: 'a1', published_version: 1, published_at: '2025-01-02' } },
        { intro: 'i', body: 'b', slug: 'newer', published: '2026-01-01', sys: { id: 'a2', published_version: 1, published_at: '2026-01-02' } }
      ]
      instance = importer(articles: articles)
      instance.send(:process_collection, :articles, :set_article_path)

      processed = instance.instance_variable_get(:@content)[:articles]
      expect(processed.map { |a| a[:slug] }).to eq(%w[newer older])
      expect(processed.first).to include(entry_type: 'Article', draft: false, template: '/article.html')
      expect(processed.first[:path]).to eq('/2026/01/01/newer/index.html')
    end
  end

  describe '#listing_page' do
    let(:articles) { (1..5).map { |n| { title: "Article #{n}" } } }
    let(:pages) { importer.send(:listing_page, articles, base_path: '/blog', template: '/articles.html', title: 'Blog') }

    it 'builds a single page at the base path listing every entry' do
      expect(pages.size).to eq(1)
      expect(pages.first[:path]).to eq('/blog/index.html')
      expect(pages.first[:items].size).to eq(5)
    end

    it 'carries the template, title, and search-indexing flag, adding a summary only when given' do
      expect(pages.first).to include(template: '/articles.html', title: 'Blog', index_in_search_engines: true)
      expect(pages.first).not_to have_key(:summary)

      with_summary = importer.send(:listing_page, articles, base_path: '/t', template: '/t.html', title: 'T', summary: 'Browse')
      expect(with_summary.first[:summary]).to eq('Browse')
    end
  end

  describe '#generate_blog' do
    it 'lists only the published articles' do
      instance = importer(articles: [
        { title: 'Live', draft: false },
        { title: 'Draft', draft: true }
      ])
      instance.send(:generate_blog)

      blog = instance.instance_variable_get(:@content)[:blog]
      expect(blog.size).to eq(1)
      expect(blog.first[:items].map { |a| a[:title] }).to eq([ 'Live' ])
    end

    # With no summary of its own, the index uses the sitewide meta description, and /blog and the
    # home page then have the same one. The count includes only the published entries.
    it 'gives the index its own summary, counting only published entries' do
      instance = importer(articles: [
        { title: 'Live', draft: false },
        { title: 'Draft', draft: true }
      ])
      instance.send(:generate_blog)

      blog = instance.instance_variable_get(:@content)[:blog]
      expect(blog.first[:summary]).to eq('Browse the complete archive of one entry, newest first.')
    end
  end

  describe 'taxonomy' do
    # A small Sports taxonomy: Triathlon > Ironman 70.3, which has a description and synonyms, a
    # Races branch with one race, and a Running topic with no children. prefLabel, definition, and
    # altLabels are locale maps, and `conceptSchemes` gives the scheme of each concept. This is the
    # shape of the delivery API.
    def sports = [ { 'sys' => { 'id' => 'sports' } } ]
    def concept_fixture
      [
        { 'sys' => { 'id' => 'triathlon' }, 'prefLabel' => { 'en-US' => 'Triathlon' }, 'conceptSchemes' => sports },
        { 'sys' => { 'id' => 'ironman-703' }, 'prefLabel' => { 'en-US' => 'Ironman 70.3' },
          'broader' => [ { 'sys' => { 'id' => 'triathlon' } } ], 'conceptSchemes' => sports,
          'definition' => { 'en-US' => 'The 70.3-mile distance.' },
          'altLabels' => { 'en-US' => [ 'Half Ironman', '70.3' ] } },
        { 'sys' => { 'id' => 'races' }, 'prefLabel' => { 'en-US' => 'Races' }, 'conceptSchemes' => sports },
        { 'sys' => { 'id' => 'cda' }, 'prefLabel' => { 'en-US' => 'CdA' },
          'broader' => [ { 'sys' => { 'id' => 'races' } } ], 'conceptSchemes' => sports },
        { 'sys' => { 'id' => 'running' }, 'prefLabel' => { 'en-US' => 'Running' }, 'conceptSchemes' => sports }
      ]
    end

    # An importer with a taxonomy fetch that gives `concepts`. An empty value means no taxonomy.
    def importer_with(concepts: concept_fixture, articles: [])
      importer(articles: articles).tap do |instance|
        allow(instance).to receive(:fetch_taxonomy_concepts).and_return(Array(concepts))
      end
    end

    # An article with the given concept ids. apply_taxonomy_to_articles reads this shape.
    def article_with(*concept_ids)
      { contentful_metadata: { concepts: concept_ids.map { |id| { id: id } } } }
    end

    describe '#build_taxonomy' do
      it 'resolves localized labels, parent from broader, and nested paths' do
        taxo = importer_with.send(:taxonomy)
        expect(taxo['ironman-703']).to include(
          name: 'Ironman 70.3', scheme: 'sports', parent_id: 'triathlon', path: '/tagged/triathlon/ironman-703/',
          description: 'The 70.3-mile distance.', synonyms: [ 'Half Ironman', '70.3' ]
        )
        expect(taxo['triathlon'][:path]).to eq('/tagged/triathlon/')
        expect(taxo['cda'][:path]).to eq('/tagged/races/cda/')
      end

      it 'derives short_name as the shortest of the name and synonyms (name wins ties)' do
        taxo = importer_with.send(:taxonomy)
        expect(taxo['ironman-703'][:short_name]).to eq('70.3')       # shorter than the name + "Half Ironman"
        expect(taxo['triathlon'][:short_name]).to eq('Triathlon')    # no synonyms → the name
      end

      it 'is empty when the endpoint yields no concepts' do
        expect(importer_with(concepts: []).send(:taxonomy)).to eq({})
      end
    end

    describe '#apply_taxonomy_to_articles' do
      it 'rebuilds tags from concepts with names and nested paths, dropping the concepts key' do
        instance = importer_with(articles: [ article_with('ironman-703', 'cda') ])
        instance.send(:apply_taxonomy_to_articles)
        article = instance.instance_variable_get(:@content)[:articles].first
        tags = article[:contentful_metadata][:tags]
        expect(tags.map { |t| t[:id] }).to eq([ 'ironman-703', 'cda' ])
        expect(tags.map { |t| t[:path] }).to eq([ '/tagged/triathlon/ironman-703/', '/tagged/races/cda/' ])
        expect(tags.map { |t| t[:short_name] }).to eq([ '70.3', 'CdA' ])
        expect(tags.map { |t| t[:synonyms] }).to eq([ [ 'Half Ironman', '70.3' ], [] ])
        expect(article[:contentful_metadata]).not_to have_key(:concepts)
      end

      it 'drops concept ids the taxonomy does not know' do
        instance = importer_with(articles: [ article_with('ironman-703', 'nope') ])
        instance.send(:apply_taxonomy_to_articles)
        tags = instance.instance_variable_get(:@content)[:articles].first[:contentful_metadata][:tags]
        expect(tags.map { |t| t[:id] }).to eq([ 'ironman-703' ])
      end
    end

    describe '#generate_tags (hierarchy-aware)' do
      def built_tags(articles)
        instance = importer_with(articles: articles)
        instance.send(:apply_taxonomy_to_articles)
        instance.send(:generate_tags)
        instance.instance_variable_get(:@content)[:tags]
      end

      it 'rolls descendants up into parents and lists all races under the Races branch' do
        tags = built_tags([ article_with('ironman-703', 'cda') ])
        ids = tags.map { |t| t[:tag][:id] }
        # Triathlon (from a child), Ironman 70.3, Races (from a child), and CdA, but not Running,
        # which has no children.
        expect(ids).to match_array(%w[triathlon ironman-703 races cda])
        expect(ids).not_to include('running')

        triathlon = tags.find { |t| t[:tag][:id] == 'triathlon' }
        expect(triathlon[:pages].first[:path]).to eq('/tagged/triathlon/index.html')
        expect(triathlon[:pages].first[:items].size).to eq(1)
        # The tag entry has its scheme and the number of articles in its archive. The breadcrumb
        # code uses that number to select between two concepts.
        expect(triathlon[:tag]).to include(scheme: 'sports', entry_count: 1)
      end

      it "uses a concept's description as the page copy, else the boilerplate summary" do
        tags = built_tags([ article_with('ironman-703') ])
        im703 = tags.find { |t| t[:tag][:id] == 'ironman-703' }
        expect(im703[:pages].first[:summary]).to eq('The 70.3-mile distance.')
        expect(im703[:pages].first[:description]).to eq('The 70.3-mile distance.')

        triathlon = tags.find { |t| t[:tag][:id] == 'triathlon' }
        expect(triathlon[:pages].first[:summary]).to eq('Browse one entry tagged “Triathlon.”')
        expect(triathlon[:pages].first).not_to have_key(:description)
      end

      it 'carries archive metadata on each tag page: tag_id and the newest entry date' do
        newer = article_with('ironman-703').merge(published_at: '2025-06-01T00:00:00Z')
        older = article_with('ironman-703').merge(published_at: '2024-06-01T00:00:00Z')
        tags = built_tags([ newer, older ]) # newest-first, as published_articles delivers them
        page = tags.find { |t| t[:tag][:id] == 'ironman-703' }[:pages].first
        expect(page).to include(tag_id: 'ironman-703', updated_at: '2025-06-01T00:00:00Z')
        expect(page).not_to have_key(:entry_count)
      end
    end
  end

  describe '#rewrite_image_urls' do
    def stub_image_host(host)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('IMAGE_HOST').and_return(host)
    end

    before { stub_image_host('images.example.com') }

    # Only the host changes. The Contentful path IS the R2 key that the api writes at, thus a
    # change to the path here would make each image on the site 404.
    it 'swaps the host and keeps the path verbatim' do
      item = transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/asset-1/token/a.jpg' })
      expect(item[:url]).to eq('https://images.example.com/space/asset-1/token/a.jpg')
    end

    # The rewrite kept the first URL as :contentful_url, because encode_blurhash resized with the
    # query parameters of the Contentful Images API and the mirror ignores a query string. It now
    # resizes with Cloudflare Images from this URL, thus no code reads the first URL.
    it 'adds no key beyond the swapped URL' do
      item = transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/asset-1/token/a.jpg' })
      expect(item.keys).to eq([ :url ])
    end

    it 'preserves a protocol-relative URL as protocol-relative' do
      item = transform(:rewrite_image_urls, { url: '//images.ctfassets.net/space/asset-1/token/a.jpg' })
      expect(item[:url]).to eq('//images.example.com/space/asset-1/token/a.jpg')
    end

    # A cache buster would cause damage: a new file for an asset gives a new token segment, thus
    # the URL already changes; the key of the mirror is the path; and Contentful refuses a
    # parameter that it does not know (ParameterNotAllowed).
    it 'adds no query string' do
      item = transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/asset-1/token/a.jpg', sys: { published_version: 3 } })
      expect(item[:url]).not_to include('?')
    end

    # ⚠️ Contentful serves some *image* assets from downloads.ctfassets.net. The two hosts are not
    # images and files. If the code matches only images.ctfassets.net, those assets go to
    # Contentful for all time, with no message, and the mirror exists to stop that. The
    # AssetMirror of the api uses the same path as its key, and that path is the same on both
    # hosts.
    it 'rewrites every ctfassets host' do
      %w[images downloads assets].each do |sub|
        item = transform(:rewrite_image_urls, { url: "https://#{sub}.ctfassets.net/space/asset-1/token/a.jpg" })
        expect(item[:url]).to eq('https://images.example.com/space/asset-1/token/a.jpg')
      end
    end

    it 'leaves non-Contentful URLs alone' do
      item = transform(:rewrite_image_urls, { url: 'https://elsewhere.example.com/a.jpg' })
      expect(item[:url]).to eq('https://elsewhere.example.com/a.jpg')
    end

    # The mirror is the ONLY host that the zone permits as a Cloudflare Images transformation
    # source. Thus a build with no rewrite does not use Contentful: it makes each image on the site
    # 403. This code did nothing before, and that gave a build where each image was broken while
    # the build reported a success.
    context 'when IMAGE_HOST is unset' do
      before { stub_image_host(nil) }

      it 'raises rather than emitting URLs that would 403' do
        expect { transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/asset-1/token/a.jpg' }) }
          .to raise_error(Contentful::ImageHostMissing, /IMAGE_HOST is unset/)
      end

      # The rescue at the method level exists so that one asset URL with an incorrect shape cannot
      # stop the import. It must not also hide the configuration error that makes the full build
      # useless.
      it 'raises past the rescue that swallows per-asset URL errors' do
        expect { transform(:rewrite_image_urls, { url: 'not a url' }) }
          .to raise_error(Contentful::ImageHostMissing)
      end
    end
  end

  describe '#get_contentful_data' do
    # One page of the GraphQL response. `items` is the true content from Contentful, and it
    # includes each null: Contentful returns null for each link that the token cannot resolve.
    def page(items)
      double(errors: double(present?: false), data: double(to_h: { 'articles' => { 'items' => items } }))
    end

    def fetch_with(pages)
      client = double
      allow(client).to receive(:query).and_return(*pages)

      instance = importer(articles: [])
      instance.instance_variable_set(:@client, client)
      allow(instance).to receive(:collection_queries).and_return(articles: 'query')
      instance.send(:get_contentful_data)
      instance.instance_variable_get(:@content)[:articles]
    end

    it 'stops at the first short page' do
      articles = fetch_with([ page(Array.new(40) { |i| { 'slug' => "a#{i}" } }) ])

      expect(articles.size).to eq(40)
    end

    # The code gets the collections on different threads, because they do not depend on each
    # other. Thus this example covers the merge: each collection must go under its own key, and no
    # collection can go into the key of another one.
    it 'fetches independent collections concurrently and merges them under their own keys' do
      client = double
      allow(client).to receive(:query) do |query, **|
        key = query.to_s
        double(
          errors: double(present?: false),
          data: double(to_h: { key => { 'items' => [ { 'slug' => "#{key}-1" } ] } })
        )
      end

      instance = importer(articles: [], pages: [], events: [])
      instance.instance_variable_set(:@client, client)
      allow(instance).to receive(:collection_queries)
        .and_return(articles: 'articles', pages: 'pages', events: 'events')

      instance.send(:get_contentful_data)
      content = instance.instance_variable_get(:@content)

      expect(content[:articles]).to eq([ { slug: 'articles-1' } ])
      expect(content[:pages]).to eq([ { slug: 'pages-1' } ])
      expect(content[:events]).to eq([ { slug: 'events-1' } ])
    end

    it 'follows the cursor across full pages' do
      articles = fetch_with([
        page(Array.new(100) { |i| { 'slug' => "a#{i}" } }),
        page(Array.new(7) { |i| { 'slug' => "b#{i}" } })
      ])

      expect(articles.size).to eq(107)
    end

    # ⚠️ This example exists for one failure: a full page with a link that the token cannot resolve
    # becomes 99 items after `compact`, and a comparison of *that* number with the limit stops the
    # pages. Thus the code loses each subsequent page of the collection, with no message and with a
    # green build.
    it 'keeps paginating when a full page contains an unresolvable link' do
      first = Array.new(100) { |i| { 'slug' => "a#{i}" } }
      first[42] = nil

      articles = fetch_with([ page(first), page([ { 'slug' => 'last' } ]) ])

      expect(articles.size).to eq(100)
      expect(articles.last[:slug]).to eq('last')
      expect(articles).not_to include(nil)
    end
  end
end
