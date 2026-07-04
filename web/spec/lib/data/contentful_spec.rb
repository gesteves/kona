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
