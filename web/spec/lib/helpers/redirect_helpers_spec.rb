require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'
require 'hashie'

# RSpec includes the module under test, thus you can call the instance methods of RedirectHelpers
# directly.
RSpec.describe RedirectHelpers do
  include_context 'default helper stubs'

  # Makes a site double with the shape of `data.site`.
  def site(socials: [], logo: 'logo', author_name: 'Jane Doe', profile_picture: nil)
    OpenStruct.new(
      title: 'My Site',
      logo: logo,
      socials_collection: OpenStruct.new(items: socials.map { |t, d| OpenStruct.new(title: t, destination: d) }),
      author: OpenStruct.new(name: author_name, profile_picture: profile_picture)
    )
  end

  # Other helper modules usually supply these methods. This file defines them, thus the test runs
  # the schema builders alone.
  def data = OpenStruct.new(site: @site || site)
  def site_icon_url(w:) = "https://example.com/icon-#{w}.png"
  def cdn_image_url(url, params = {}) = "#{url}?w=#{params[:w]}"

  describe '#taxonomy_synonym_redirects' do
    def data
      OpenStruct.new(
        tags: [
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/triathlon/ironman-703/', synonyms: [ 'Half Ironman', '70.3' ])),
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/running/', synonyms: [])),
          OpenStruct.new(tag: OpenStruct.new(path: '/tagged/triathlon/', synonyms: [ 'Multisport' ]))
        ],
        redirects: [ OpenStruct.new(from: '/tagged/multisport') ] # a configured redirect already claims this
      )
    end

    it 'maps synonym slugs to the canonical concept page, with and without a slash at the end' do
      expect(taxonomy_synonym_redirects).to include(
        { from: '/tagged/half-ironman', to: '/tagged/triathlon/ironman-703/', status: 301 },
        { from: '/tagged/half-ironman/', to: '/tagged/triathlon/ironman-703/', status: 301 },
        { from: '/tagged/70-3', to: '/tagged/triathlon/ironman-703/', status: 301 },
        { from: '/tagged/70-3/', to: '/tagged/triathlon/ironman-703/', status: 301 }
      )
    end

    it 'skips synonyms that collide with a configured redirect' do
      froms = taxonomy_synonym_redirects.map { |r| r[:from] }
      expect(froms).not_to include('/tagged/multisport')
      expect(froms).not_to include('/tagged/multisport/')
    end
  end

  # ⚠️ The division into static rules and dynamic rules is a rule that a change can break, and it is
  # not a style choice. The Cloudflare parser latches at the first dynamic rule and counts each rule
  # after it, exact matches included, against the limit of 100 dynamic rules. This code was in
  # redirects.erb, and you cannot test a template.
  describe '#partitioned_redirects' do
    def taxonomy_synonym_redirects
      [ { from: '/tagged/half-ironman', to: '/tagged/triathlon/ironman-703/', status: 301 } ]
    end

    def data
      OpenStruct.new(redirects: @redirects || [])
    end

    def redirect(from, to, status = 301)
      OpenStruct.new(from: from, to: to, status: status)
    end

    it 'emits every exact-match rule before any splat or placeholder rule' do
      @redirects = [
        redirect('/old-splat/*', '/new/:splat'),
        redirect('/exact-one', '/new-one'),
        redirect('/with/:placeholder', '/other/:placeholder'),
        redirect('/exact-two', '/new-two')
      ]

      static_rules, dynamic_rules = partitioned_redirects

      expect(static_rules.map { |r| r[:from] }).to eq([ '/tagged/half-ironman', '/exact-one', '/exact-two' ])
      expect(dynamic_rules.map { |r| r[:from] })
        .to eq([ '/.well-known/host-meta*', '/.well-known/webfinger*', '/old-splat/*', '/with/:placeholder' ])
    end

    # A person writes each redirect in Contentful, and the deploy must not break for it.
    it 'drops a redirect from a path to itself, and keeps the first of two rules with one source' do
      @redirects = [
        redirect('/blog', '/blog/'),
        redirect('/old', '/new-one'),
        redirect('/old', '/new-two')
      ]

      static_rules, _ = partitioned_redirects
      rules = static_rules.select { |r| %w[/blog /old].include?(r[:from]) }
      expect(rules).to eq([ { from: '/old', to: '/new-one', status: 301 } ])
    end

    it 'counts the taxonomy synonym redirects as static' do
      static_rules, _ = partitioned_redirects

      expect(static_rules.map { |r| r[:from] }).to include('/tagged/half-ironman')
    end

    # Both stop a deploy (code 100324), and a Contentful entry can cause them.
    it 'drops an absolute-URL source' do
      @redirects = [ redirect('https://old.example.com/post', '/post') ]

      expect(partitioned_redirects.flatten.map { |r| r[:from] }).not_to include('https://old.example.com/post')
    end

    it 'drops a 200 proxy rewrite pointing at an absolute URL' do
      @redirects = [
        redirect('/proxied', 'https://upstream.example.com/thing', 200),
        redirect('/proxied-relative', '/thing', 200)
      ]

      froms = partitioned_redirects.flatten.map { |r| r[:from] }
      expect(froms).not_to include('/proxied')
      expect(froms).to include('/proxied-relative')
    end
  end

  describe '#dynamic_redirect_source?' do
    it 'is true for a splat or a :placeholder, false for an exact path' do
      expect(dynamic_redirect_source?('/a/*')).to be(true)
      expect(dynamic_redirect_source?('/a/:name')).to be(true)
      expect(dynamic_redirect_source?('/a/b')).to be(false)
      expect(dynamic_redirect_source?('/a/b.html')).to be(false)
    end

    # This matches too much, on purpose: a colon with a letter after it counts at each position,
    # thus a source that only looks like a placeholder becomes a dynamic rule. A static rule that
    # this code calls dynamic causes no damage. A dynamic rule that this code calls static stops the
    # deploy.
    it 'treats a mid-segment colon as a placeholder' do
      expect(dynamic_redirect_source?('/a:b')).to be(true)
    end
  end
end
