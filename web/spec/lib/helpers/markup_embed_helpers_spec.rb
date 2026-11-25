require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'

RSpec.describe MarkupEmbedHelpers do
  include Padrino::Helpers
  include SiteHelpers
  include Padrino::Helpers::TagHelpers

  describe '#add_figure_elements_to_iframes' do
    let(:iframe_html) { '<iframe src="https://player.example/embed/1"></iframe>' }

    context 'with a base class' do
      # ⚠️ The figure replaces the paragraph, as it does for an image. A <figure> inside a <p> is
      # not valid HTML, and the browser would close the paragraph at the figure.
      it 'replaces the paragraph with a figure that has the base and iframe modifier classes' do
        transformed_html = add_figure_elements_to_iframes("<p>#{iframe_html}</p>", base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure>))
      end

      it 'puts the other content of the paragraph in a figcaption' do
        transformed_html = add_figure_elements_to_iframes("<p>Watch this: #{iframe_html} <em>live</em></p>", base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--iframe">#{iframe_html}<figcaption>Watch this:  <em>live</em></figcaption></figure>))
      end

      it 'keeps the figure in place for a paragraph with two iframes' do
        transformed_html = add_figure_elements_to_iframes("<p>#{iframe_html}#{iframe_html}</p>", base_class: 'entry')
        expect(transformed_html).to eq(%(<p><figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure><figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure></p>))
      end

      it 'wraps an iframe outside a paragraph in place' do
        transformed_html = add_figure_elements_to_iframes("<div>#{iframe_html}</div>", base_class: 'entry')
        expect(transformed_html).to eq(%(<div><figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure></div>))
      end

      it 'reuses an existing figure parent, replacing its class instead of nesting a new figure' do
        transformed_html = add_figure_elements_to_iframes("<figure>#{iframe_html}</figure>", base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--iframe">#{iframe_html}</figure>))
      end
    end

    context 'without a base class' do
      it 'wraps the iframe in a classless figure' do
        transformed_html = add_figure_elements_to_iframes("<p>#{iframe_html}</p>")
        expect(transformed_html).to eq(%(<figure>#{iframe_html}</figure>))
      end
    end
  end

  describe '#add_figure_elements_to_embeds' do
    let(:embed_html) { '<blockquote class="bluesky-embed"><p>A post</p></blockquote><script src="https://embed.bsky.app/static/embed.js"></script>' }

    context 'with a base class' do
      it 'wraps the blockquote + script pair in a figure with the base and embed modifier classes' do
        transformed_html = add_figure_elements_to_embeds(embed_html, base_class: 'entry')
        # Nokogiri writes a newline before the <script>. The test uses that exact output.
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--embed"><blockquote class="bluesky-embed"><p>A post</p></blockquote>\n<script src="https://embed.bsky.app/static/embed.js"></script></figure>))
      end

      it 'reuses an existing figure parent, replacing its class instead of nesting a new figure' do
        transformed_html = add_figure_elements_to_embeds("<figure>#{embed_html}</figure>", base_class: 'entry')
        expect(transformed_html).to eq(%(<figure class="entry__figure entry__figure--embed"><blockquote class="bluesky-embed"><p>A post</p></blockquote>\n<script src="https://embed.bsky.app/static/embed.js"></script></figure>))
      end
    end

    it 'leaves a blockquote without a following script untouched' do
      html = '<blockquote><p>A post</p></blockquote>'
      expect(add_figure_elements_to_embeds(html, base_class: 'entry')).to eq(html)
    end
  end

  # ⚠️ A frame with no accessible name is a serious WCAG failure, and a podcast embed from the
  # Contentful body has no title of its own.
  describe '#set_iframe_titles' do
    it 'names an iframe from the host that it embeds' do
      html = %(<iframe src="https://embed.podcasts.apple.com/us/podcast/x"></iframe>)
      expect(set_iframe_titles(html)).to include('title="Embedded content from embed.podcasts.apple.com"')
    end

    it 'prefers the caption of the figure' do
      html = %(<figure><iframe src="https://example.com/x"></iframe><figcaption>Episode 12</figcaption></figure>)
      expect(set_iframe_titles(html)).to include('title="Episode 12"')
    end

    it 'never replaces a title that the author wrote' do
      html = %(<iframe src="https://example.com/x" title="My player"></iframe>)
      result = set_iframe_titles(html)
      expect(result).to include('title="My player"')
      expect(result).not_to include('Embedded content')
    end

    it 'falls back when the src is absent' do
      expect(set_iframe_titles('<iframe></iframe>')).to include('title="Embedded content"')
    end

    it 'removes a www prefix from the host' do
      html = %(<iframe src="https://www.youtube.com/embed/x"></iframe>)
      expect(set_iframe_titles(html)).to include('title="Embedded content from youtube.com"')
    end
  end

  describe '#responsivize_iframes' do
    it 'removes the width rules from the inline style and keeps the other rules' do
      html = '<iframe height="160" width="640" style="width:100%;max-width:640px;overflow:hidden;border-radius:12px;" src="https://embed.podcasts.apple.com/us/podcast/x"></iframe>'
      expect(responsivize_iframes(html)).to eq('<iframe height="160" width="640" style="overflow:hidden;border-radius:12px" src="https://embed.podcasts.apple.com/us/podcast/x"></iframe>')
    end

    it 'removes a style that holds only width rules' do
      html = '<iframe style="Max-Width: 640px; width: 100%" src="https://player.example/embed/1"></iframe>'
      expect(responsivize_iframes(html)).to eq('<iframe src="https://player.example/embed/1"></iframe>')
    end

    it 'leaves an iframe with no style unchanged' do
      html = '<iframe src="https://player.example/embed/1"></iframe>'
      expect(responsivize_iframes(html)).to eq(html)
    end

    it 'removes the width and the height of a Spotify video episode' do
      html = '<iframe style="border-radius:12px" src="https://open.spotify.com/embed/episode/2borPjAt3Ot3ugUdrGAnu4/video?utm_source=generator" width="624" height="351"></iframe>'
      expect(responsivize_iframes(html)).to eq('<iframe style="border-radius:12px" src="https://open.spotify.com/embed/episode/2borPjAt3Ot3ugUdrGAnu4/video?utm_source=generator"></iframe>')
    end

    it 'removes the width and the height of a YouTube video' do
      html = '<iframe width="560" height="315" src="https://www.youtube-nocookie.com/embed/abc_123"></iframe>'
      expect(responsivize_iframes(html)).to eq('<iframe src="https://www.youtube-nocookie.com/embed/abc_123"></iframe>')
    end

    it 'keeps the height of an audio player' do
      html = '<iframe src="https://open.spotify.com/embed/episode/2borPjAt3Ot3ugUdrGAnu4?utm_source=generator" width="100%" height="152"></iframe>'
      expect(responsivize_iframes(html)).to eq(html)
    end
  end

  describe '#lazy_load_iframes' do
    it 'adds loading="lazy" to iframes' do
      html = '<iframe src="https://player.example/embed/1"></iframe>'
      transformed_html = lazy_load_iframes(html)
      expect(transformed_html).to eq('<iframe src="https://player.example/embed/1" loading="lazy"></iframe>')
    end
  end
end
