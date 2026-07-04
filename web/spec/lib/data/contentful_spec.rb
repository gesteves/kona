require 'spec_helper'

# lib/data/contentful.rb requires graphql/contentful, which introspects the live Contentful
# schema at load time (network + credentials, unavailable in CI). Register a stand-in module
# and mark that file as loaded so its require becomes a no-op — these specs cover the pure
# transform methods only, never the fetch.
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
  # The initializer fetches everything from Contentful; allocate skips it so the transform
  # methods can be exercised against hand-built @content.
  def importer(content = {})
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@content, { site: { entries_per_page: 2 } }.merge(content))
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

  describe '#paginate' do
    let(:articles) { (1..5).map { |n| { title: "Article #{n}" } } }
    let(:pages) { importer.send(:paginate, articles, base_path: '/blog', template: '/articles.html', title: 'Blog') }

    it 'slices the collection by the site page size' do
      expect(pages.size).to eq(3)
      expect(pages.first[:items].size).to eq(2)
      expect(pages.last[:items].size).to eq(1)
    end

    it 'puts page one at the base path and later pages under page/N' do
      expect(pages.map { |p| p[:path] }).to eq([
        '/blog/index.html', '/blog/page/2/index.html', '/blog/page/3/index.html'
      ])
    end

    it 'links neighboring pages' do
      expect(pages[0]).to include(current_page: 1, previous_page: nil, next_page: 2, next_page_path: '/blog/page/2/index.html')
      expect(pages[1]).to include(current_page: 2, previous_page: 1, previous_page_path: '/blog/index.html')
      expect(pages[2]).to include(current_page: 3, next_page: nil, next_page_path: nil)
    end

    it 'carries the template, title, and search-indexing flag, adding a summary only when given' do
      expect(pages.first).to include(template: '/articles.html', title: 'Blog', index_in_search_engines: true)
      expect(pages.first).not_to have_key(:summary)

      with_summary = importer.send(:paginate, articles, base_path: '/t', template: '/t.html', title: 'T', summary: 'Browse')
      expect(with_summary.first[:summary]).to eq('Browse')
    end
  end

  describe '#generate_blog' do
    it 'paginates only the published articles' do
      instance = importer(articles: [
        { title: 'Live', draft: false },
        { title: 'Draft', draft: true }
      ])
      instance.send(:generate_blog)

      blog = instance.instance_variable_get(:@content)[:blog]
      expect(blog.size).to eq(1)
      expect(blog.first[:items].map { |a| a[:title] }).to eq(['Live'])
    end
  end

  describe 'taxonomy' do
    # A small taxonomy: Triathlon > Ironman 70.3 (with a description + synonyms), a Races
    # branch with one race, and a childless Running topic. prefLabel/definition/altLabels are
    # locale maps, matching the delivery API shape.
    def concept_fixture
      [
        { 'sys' => { 'id' => 'triathlon' }, 'prefLabel' => { 'en-US' => 'Triathlon' } },
        { 'sys' => { 'id' => 'ironman-703' }, 'prefLabel' => { 'en-US' => 'Ironman 70.3' },
          'broader' => [{ 'sys' => { 'id' => 'triathlon' } }],
          'definition' => { 'en-US' => 'The 70.3-mile distance.' },
          'altLabels' => { 'en-US' => ['Half Ironman', '70.3'] } },
        { 'sys' => { 'id' => 'races' }, 'prefLabel' => { 'en-US' => 'Races' } },
        { 'sys' => { 'id' => 'cda' }, 'prefLabel' => { 'en-US' => 'CdA' },
          'broader' => [{ 'sys' => { 'id' => 'races' } }] },
        { 'sys' => { 'id' => 'running' }, 'prefLabel' => { 'en-US' => 'Running' } }
      ]
    end

    # An importer whose taxonomy fetch is stubbed to `concepts` (nil = the 404/empty fallback).
    def importer_with(concepts: concept_fixture, articles: [])
      importer(articles: articles).tap do |instance|
        allow(instance).to receive(:fetch_taxonomy_concepts).and_return(Array(concepts))
      end
    end

    def article_with(concepts: nil, tags: nil)
      cm = {}
      cm[:tags] = tags if tags
      cm[:concepts] = concepts if concepts
      { contentful_metadata: cm }
    end

    describe '#build_taxonomy' do
      it 'resolves localized labels, parent from broader, and nested paths' do
        taxo = importer_with.send(:taxonomy)
        expect(taxo['ironman-703']).to include(
          name: 'Ironman 70.3', parent_id: 'triathlon', path: '/tagged/triathlon/ironman-703',
          description: 'The 70.3-mile distance.', synonyms: ['Half Ironman', '70.3']
        )
        expect(taxo['triathlon'][:path]).to eq('/tagged/triathlon')
        expect(taxo['cda'][:path]).to eq('/tagged/races/cda')
      end

      it 'derives short_name as the shortest of the name and synonyms (name wins ties)' do
        taxo = importer_with.send(:taxonomy)
        expect(taxo['ironman-703'][:short_name]).to eq('70.3')       # shorter than the name + "Half Ironman"
        expect(taxo['triathlon'][:short_name]).to eq('Triathlon')    # no synonyms → the name
      end

      it 'is empty (fallback) when the endpoint yields nothing' do
        expect(importer_with(concepts: []).send(:taxonomy)).to eq({})
      end
    end

    describe '#apply_taxonomy_to_articles' do
      it 'rebuilds tags from concepts with names and nested paths, dropping the concepts key' do
        instance = importer_with(articles: [article_with(
          tags: [{ id: 'ironman-703', name: 'Ironman 70.3' }],
          concepts: [{ id: 'ironman-703' }, { id: 'cda' }]
        )])
        instance.send(:apply_taxonomy_to_articles)
        tags = instance.instance_variable_get(:@content)[:articles].first[:contentful_metadata][:tags]
        expect(tags.map { |t| t[:id] }).to eq(['ironman-703', 'cda'])
        expect(tags.map { |t| t[:path] }).to eq(['/tagged/triathlon/ironman-703', '/tagged/races/cda'])
        expect(tags.map { |t| t[:short_name] }).to eq(['70.3', 'CdA'])
        expect(instance.instance_variable_get(:@content)[:articles].first[:contentful_metadata]).not_to have_key(:concepts)
      end

      it 'falls back to legacy tags (with /tagged/<id> paths) when concepts are absent' do
        instance = importer_with(concepts: [], articles: [article_with(tags: [{ id: 'gear', name: 'Gear' }])])
        instance.send(:apply_taxonomy_to_articles)
        tags = instance.instance_variable_get(:@content)[:articles].first[:contentful_metadata][:tags]
        expect(tags).to eq([{ id: 'gear', name: 'Gear', short_name: 'Gear', parent_id: nil, path: '/tagged/gear' }])
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
        tags = built_tags([article_with(tags: [{ id: 'ironman-703', name: 'Ironman 70.3' }],
                                        concepts: [{ id: 'ironman-703' }, { id: 'cda' }])])
        ids = tags.map { |t| t[:tag][:id] }
        # Triathlon (via descendant), Ironman 70.3, Races (via descendant), CdA — but not childless Running.
        expect(ids).to match_array(%w[triathlon ironman-703 races cda])
        expect(ids).not_to include('running')

        triathlon = tags.find { |t| t[:tag][:id] == 'triathlon' }
        expect(triathlon[:pages].first[:path]).to eq('/tagged/triathlon/index.html')
        expect(triathlon[:pages].first[:items].size).to eq(1)
      end

      it "uses a concept's description as the page copy, else the boilerplate summary" do
        tags = built_tags([article_with(tags: [{ id: 'ironman-703', name: 'Ironman 70.3' }],
                                        concepts: [{ id: 'ironman-703' }])])
        im703 = tags.find { |t| t[:tag][:id] == 'ironman-703' }
        expect(im703[:pages].first[:summary]).to eq('The 70.3-mile distance.')
        expect(im703[:pages].first[:description]).to eq('The 70.3-mile distance.')

        triathlon = tags.find { |t| t[:tag][:id] == 'triathlon' }
        expect(triathlon[:pages].first[:summary]).to eq('Browse one entry tagged “Triathlon.”')
        expect(triathlon[:pages].first).not_to have_key(:description)
      end

      it 'falls back to flat legacy tag pages when the taxonomy is unavailable' do
        instance = importer_with(concepts: [], articles: [article_with(tags: [{ id: 'gear', name: 'Gear' }])])
        instance.send(:apply_taxonomy_to_articles)
        instance.send(:generate_tags)
        tags = instance.instance_variable_get(:@content)[:tags]
        expect(tags.map { |t| t[:tag][:id] }).to eq(['gear'])
        expect(tags.first[:pages].first[:path]).to eq('/tagged/gear/index.html')
      end
    end
  end

  describe '#rewrite_image_urls' do
    def with_cloudfront(domain)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('CLOUDFRONT_DOMAIN').and_return(domain)
    end

    it 'rewrites Contentful asset URLs to CloudFront with a cache-busting version' do
      with_cloudfront('cdn.example.com')
      item = transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/a.jpg', sys: { published_version: 3 } })
      expect(item[:url]).to eq('https://cdn.example.com/space/a.jpg?v=3')
    end

    it 'appends the version to an existing query string' do
      with_cloudfront('cdn.example.com')
      item = transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/a.jpg?fm=jpg', sys: { published_version: 3 } })
      expect(item[:url]).to eq('https://cdn.example.com/space/a.jpg?fm=jpg&v=3')
    end

    it 'leaves non-Contentful URLs alone' do
      with_cloudfront('cdn.example.com')
      item = transform(:rewrite_image_urls, { url: 'https://elsewhere.example.com/a.jpg', sys: { published_version: 3 } })
      expect(item[:url]).to eq('https://elsewhere.example.com/a.jpg')
    end

    it 'is a no-op without a CloudFront domain' do
      with_cloudfront(nil)
      item = transform(:rewrite_image_urls, { url: 'https://images.ctfassets.net/space/a.jpg', sys: { published_version: 3 } })
      expect(item[:url]).to eq('https://images.ctfassets.net/space/a.jpg')
    end
  end
end
