require "rails_helper"

RSpec.describe ImagesHelper do
  subject(:helper) { ActionView::Base.empty.extend(described_class) }

  let(:asset_url) { "https://images.ctfassets.net/space/asset1/token/photo.jpg" }

  # ⚠️ Each expected card size below comes from config/srcsets.yml. Thus a change to the shape or
  # to the widths needs an edit in that ONE file, and no edit here. These read the file directly,
  # and they do not use the constants under test: a helper that parses `ratio` incorrectly must
  # fail. srcsets_contract_spec.rb pins the width:height syntax and the copy from web.
  def card_config = YAML.load_file(Rails.root.join("config/srcsets.yml")).fetch("card")

  # @return [Array<Integer>] The candidate widths, the smallest first, as the helper sorts them.
  def card_candidate_widths = card_config.fetch("widths").sort

  # @return [Integer] The height of a card candidate at that width.
  def card_height(width)
    w, h = card_config.fetch("ratio").split(":", 2).map(&:to_i)
    (width * Rational(h, w)).round
  end

  def stub_images(images_url: "https://site.example", image_host: "images.example")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("IMAGES_URL").and_return(images_url)
    allow(ENV).to receive(:[]).with("IMAGE_HOST").and_return(image_host)
  end

  def article(url: "https://images.ctfassets.net/space/asset1/token/photo.jpg", width: 3000,
              height: 2000, content_type: "image/jpeg", asset_id: "asset1", version: 3)
    cover = url && {
      url: url, width: width, height: height, content_type: content_type,
      sys: { id: asset_id, published_version: version }
    }
    DeepOstruct.wrap(title: "A post", path: "/a/", cover_image: cover)
  end

  before { allow_any_instance_of(BlurhashPlaceholder).to receive(:read).and_return(nil) }

  describe "#cdn_image_url" do
    it "makes a transformation URL on IMAGES_URL, from the mirror host" do
      stub_images
      expect(helper.cdn_image_url(asset_url, w: 100, h: 50, fit: "cover"))
        .to eq("https://site.example/cdn-cgi/image/width=100,height=50,fit=cover/https://images.example/space/asset1/token/photo.jpg")
    end

    it "keeps the Contentful path word for word" do
      stub_images
      expect(helper.cdn_image_url(asset_url, w: 100)).to include("/space/asset1/token/photo.jpg")
    end

    it "matches each ctfassets host, and not only the images host" do
      stub_images
      expect(helper.cdn_image_url("//downloads.ctfassets.net/space/a/t/f.jpg", w: 100))
        .to include("https://images.example/space/a/t/f.jpg")
    end

    it "gives anim=true when there is no parameter, because Cloudflare refuses no options" do
      stub_images
      expect(helper.cdn_image_url(asset_url)).to include("/cdn-cgi/image/anim=true/")
    end

    it "returns nil when IMAGES_URL has no value" do
      stub_images(images_url: nil)
      expect(helper.cdn_image_url(asset_url, w: 100)).to be_nil
    end

    it "returns nil when IMAGE_HOST has no value" do
      stub_images(image_host: nil)
      expect(helper.cdn_image_url(asset_url, w: 100)).to be_nil
    end

    it "returns nil for a host that is not ctfassets, thus no other host becomes a source" do
      stub_images
      expect(helper.cdn_image_url("https://example.com/a.jpg", w: 100)).to be_nil
    end

    it "returns nil for a blank URL" do
      stub_images
      expect(helper.cdn_image_url(nil, w: 100)).to be_nil
    end
  end

  describe "#cover_image_tag" do
    before { stub_images }

    it "makes an img with the card size, an empty alt, and the placeholder attributes" do
      html = helper.cover_image_tag(article)

      expect(html).to include(%(width="#{card_candidate_widths.first}"))
      expect(html).to include(%(height="#{card_height(card_candidate_widths.first)}"))
      expect(html).to include('alt=""')
      expect(html).to include('loading="lazy"')
      expect(html).to include('decoding="async"')
      expect(html).to include('class="entry__cover-image placeholder"')
      expect(html).to include('data-controller="image-placeholder"')
    end

    it "cuts each candidate to the card ratio" do
      html = helper.cover_image_tag(article)

      [ card_candidate_widths.first, card_candidate_widths.last ].each do |w|
        expect(html).to include("width=#{w},height=#{card_height(w)},fit=cover")
      end
    end

    # ⚠️ Cloudflare renders and bills one transformation for each different URL. A src with
    # parameters that only look the same is a second render of each cover image that no browser
    # uses.
    it "uses one of its own srcset candidates as the src" do
      html = helper.cover_image_tag(article).to_s
      src = html[/\ssrc="([^"]+)"/, 1]
      candidates = html[/srcset="([^"]+)"/, 1].split(", ").map { |c| c.split(" ").first }

      expect(candidates).to include(src)
    end

    it "gives a GIF a src with no transformation, thus it keeps its animation" do
      expect(helper.cover_image_tag(article(content_type: "image/gif"))).to include("/cdn-cgi/image/anim=true/")
    end

    it "removes each candidate that is wider than the asset" do
      html = helper.cover_image_tag(article(width: 700, height: 500))

      expect(html).to include("700w")
      expect(html).not_to include("#{card_candidate_widths.last}w")
    end

    it "gives a GIF no srcset, because a transformation removes its animation" do
      html = helper.cover_image_tag(article(content_type: "image/gif"))

      expect(html).not_to include("srcset")
      expect(html).not_to include("sizes")
    end

    it "writes the blurhash placeholder as a custom property" do
      allow_any_instance_of(BlurhashPlaceholder).to receive(:read).and_return("data:image/svg+xml,x")

      expect(helper.cover_image_tag(article)).to include("--placeholder:url(")
    end

    it "writes no custom property when there is no placeholder" do
      expect(helper.cover_image_tag(article)).not_to include("--placeholder")
    end

    it "returns nil when the article has no cover image" do
      expect(helper.cover_image_tag(article(url: nil))).to be_nil
    end

    it "returns nil when the app cannot make a URL, and never a ctfassets src" do
      stub_images(image_host: nil)

      expect(helper.cover_image_tag(article)).to be_nil
    end
  end
end
