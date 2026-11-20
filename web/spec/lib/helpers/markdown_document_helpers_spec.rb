require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'

RSpec.describe MarkdownDocumentHelpers do
  include Padrino::Helpers
  include SiteHelpers
  include Padrino::Helpers::TagHelpers

  describe '#render_markdown_body' do
    let(:base_url) { 'https://www.example.com/about/' }
    let(:image_url) { '//images.ctfassets.net/space/asset-1/token/photo.jpg' }
    let(:cdn_url) { 'https://images.example.com/cdn-cgi/image/width=1000/https://mirror.example.com/space/asset-1/token/photo.jpg' }

    def data
      OpenStruct.new(articles: [], assets: [], srcsets: OpenStruct.new(entry: OpenStruct.new(widths: [ 100, 1000 ])))
    end

    before do
      allow(self).to receive(:cdn_image_url).and_return(cdn_url)
      allow(self).to receive(:get_asset_dimensions).with('asset-1').and_return([ 3000, 2000 ])
      allow(self).to receive(:get_asset_content_type).with('asset-1').and_return('image/jpeg')
      allow(self).to receive(:get_asset_description).with('asset-1').and_return('A swimmer, mid-stroke')
    end

    def render(text)
      render_markdown_body(text, base_url: base_url)
    end

    # ⚠️ The zone refuses a ctfassets URL as an image source, and the mirror exists to keep it off
    # the site.
    it 'points each image at the CDN, with the asset description as its alt text' do
      markdown = render("![IMG 1](#{image_url})")

      expect(markdown).to eq("![A swimmer, mid-stroke](#{cdn_url})")
      expect(markdown).not_to include('ctfassets')
    end

    it 'puts the caption of an image in a paragraph, and its credit after the separator' do
      markdown = render("![IMG 1](#{image_url})\nIn the lake. | Credit: Kate")

      expect(markdown).to eq("![A swimmer, mid-stroke](#{cdn_url})\n\nIn the lake. | Credit: Kate")
    end

    it 'gives a credit with no caption no separator' do
      markdown = render("![IMG 1](#{image_url})\n | Credit: Kate")

      expect(markdown).to end_with("\n\nCredit: Kate")
    end

    it 'keeps the typography of SmartyPants and corrects the degrees' do
      expect(render(%q(It's "hot"---20º.))).to eq('It’s “hot”—20°.')
    end

    it 'changes a YouTube embed into a link to its watch page' do
      markdown = render('<iframe src="https://www.youtube-nocookie.com/embed/abc_123" title="YouTube video player"></iframe>')

      expect(markdown).to eq('[Watch on YouTube](https://www.youtube.com/watch?v=abc_123)')
    end

    it 'changes another iframe into a link to its source, with its title' do
      markdown = render('<iframe src="https://player.example/embed/1" title="A route map"></iframe>')

      expect(markdown).to eq('[A route map](https://player.example/embed/1)')
    end

    it 'keeps the quote of a social embed and removes its script' do
      markdown = render(%(<blockquote class="bluesky-embed"><p>Hello</p></blockquote><script src="https://embed.example/x.js"></script>))

      expect(markdown).to eq('> Hello')
    end

    it 'gives a cite emphasis and gives a units span both of its values' do
      expect(render('<cite>Given to Tri</cite>')).to eq('_Given to Tri_')
      expect(render('Run <span data-imperial="6.21 mi">10 km</span>.')).to eq('Run 10 km (6.21 mi).')
    end

    it 'makes each relative link absolute and leaves the other links as they are' do
      markdown = render('[Blog](/blog/), [top](#top), and [mail](mailto:hi@example.com).')

      expect(markdown).to eq('[Blog](https://www.example.com/blog/), [top](https://www.example.com/about/#top), and [mail](mailto:hi@example.com).')
    end

    it 'writes no HTML element' do
      markdown = render("![IMG 1](#{image_url})\nCaption | Credit\n\n<iframe src=\"https://player.example/embed/1\"></iframe>\n\nA <sup>1</sup> <abbr>abbr</abbr>.")

      expect(markdown).not_to match(/<[a-z]/i)
    end

    it 'returns nil for a blank input' do
      expect(render('')).to be_nil
    end
  end
end
