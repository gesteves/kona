require 'spec_helper'
require_relative '../lib/data/standard_site'

describe StandardSite do
  subject(:client) { described_class.new }

  let(:publication_uri) { 'at://did:plc:abc123/site.standard.publication/self' }

  # A new instance has no session, so the pure record builders never hit the
  # network (upload_image_blob short-circuits when there's no access token).
  let(:site) do
    {
      'title' => 'Given to Tri',
      'meta_description' => 'A triathlon training & racing blog.',
      'logo' => { 'url' => '//images.ctfassets.net/x/y/z/avatar.png', 'content_type' => 'image/png' }
    }
  end

  let(:post) do
    {
      'sys' => { 'id' => '6L1asJJq4umcGEvD0hfqxE' },
      'title' => 'Ironman updates their competition rules for 2026',
      'slug' => 'ironman-competition-rules-2026',
      'summary' => nil,
      'intro' => 'Some **bold** intro with a [link](https://example.com).',
      'body' => 'The body of the post.',
      'entry_type' => 'Short',
      'draft' => false,
      'published_at' => '2026-02-24T15:00:00.000-07:00',
      'updated_at' => '2026-02-24T22:07:58.616Z',
      'path' => '/2026/02/24/ironman-competition-rules-2026/index.html',
      'contentful_metadata' => { 'tags' => [{ 'id' => 'ironman', 'name' => 'Ironman' }, { 'id' => 'news', 'name' => 'News' }] }
    }
  end

  around do |example|
    original = ENV['URL']
    ENV['URL'] = 'https://www.giventotri.com'
    example.run
    ENV['URL'] = original
  end

  describe '#build_publication_record' do
    subject(:record) { client.build_publication_record(site) }

    it 'sets the lexicon type and the discovery preference' do
      expect(record['$type']).to eq('site.standard.publication')
      expect(record['preferences']).to eq('showInDiscover' => true)
    end

    it 'uses the production root URL without a trailing slash' do
      expect(record['url']).to eq('https://www.giventotri.com')
    end

    it 'carries the name and a plain-text description' do
      expect(record['name']).to eq('Given to Tri')
      expect(record['description']).to eq('A triathlon training & racing blog.')
    end

    it 'omits the icon when there is no PDS session' do
      expect(record).not_to have_key('icon')
    end
  end

  describe '#build_document_record' do
    subject(:record) { client.build_document_record(post, publication_uri) }

    it 'sets the lexicon type and points at the publication' do
      expect(record['$type']).to eq('site.standard.document')
      expect(record['site']).to eq(publication_uri)
    end

    it 'normalizes the path to the canonical page URL (no index.html, trailing slash kept)' do
      expect(record['path']).to eq('/2026/02/24/ironman-competition-rules-2026/')
    end

    it 'emits RFC3339 UTC timestamps' do
      expect(record['publishedAt']).to eq('2026-02-24T22:00:00.000Z')
      expect(record['updatedAt']).to eq('2026-02-24T22:07:58.616Z')
    end

    it 'derives a plain-text description from the intro when no summary is set' do
      expect(record['description']).to eq('Some bold intro with a link.')
    end

    it 'strips markdown from the textContent' do
      expect(record['textContent']).to eq('Some bold intro with a link. The body of the post.')
    end

    it 'maps tag names without hashtags' do
      expect(record['tags']).to eq(%w[Ironman News])
    end

    it 'omits the cover image when there is no PDS session' do
      expect(record).not_to have_key('coverImage')
    end

    it 'prefers an explicit summary over the intro' do
      record = client.build_document_record(post.merge('summary' => 'A short summary.'), publication_uri)
      expect(record['description']).to eq('A short summary.')
    end
  end

  describe '#publishable_posts' do
    let(:articles) do
      [
        post,
        post.merge('slug' => 'a-draft', 'draft' => true),
        post.merge('slug' => 'a-page', 'entry_type' => 'Page'),
        post.merge('slug' => 'an-article', 'entry_type' => 'Article')
      ]
    end

    it 'keeps only non-draft articles and shorts' do
      slugs = client.publishable_posts(articles).map { |a| a['slug'] }
      expect(slugs).to contain_exactly('ironman-competition-rules-2026', 'an-article')
    end
  end

  describe '#rkeys_to_prune' do
    it 'returns existing rkeys that are not in the current set' do
      expect(client.rkeys_to_prune(%w[a b c], %w[b])).to eq(%w[a c])
    end

    it 'returns nothing when every existing record is still current' do
      expect(client.rkeys_to_prune(%w[a b], %w[a b c])).to eq([])
    end

    it 'handles empty inputs' do
      expect(client.rkeys_to_prune([], %w[a])).to eq([])
    end
  end
end
