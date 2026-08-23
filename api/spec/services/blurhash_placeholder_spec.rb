require "rails_helper"

describe BlurhashPlaceholder do
  subject(:service) { described_class.new }

  let(:contentful) { instance_double(ContentfulClient) }
  let(:asset_url) { "https://images.ctfassets.net/space/asset1/token/photo.jpg" }
  let(:asset) do
    { url: asset_url, width: 3000, height: 2000, contentType: "image/jpeg",
      sys: { publishedVersion: 3 } }
  end

  before do
    allow(ContentfulClient).to receive(:new).and_return(contentful)
    allow(contentful).to receive(:items).and_return([ asset ])
    allow($redis).to receive(:exists?).and_return(false)
    allow($redis).to receive(:set)
  end

  # A 4x4 JPEG, which is enough for the encode.
  def thumbnail
    Vips::Image.black(4, 4).copy(interpretation: :srgb).write_to_buffer(".jpg")
  end

  def stub_fetch(data = thumbnail)
    allow(URI).to receive(:open).and_return(StringIO.new(data))
  end

  describe "#generate" do
    it "stores an SVG data URI under the asset id and its published version" do
      stub_fetch

      expect($redis).to receive(:set).with("blurhash:svg:asset1:3", /\Adata:image\/svg\+xml/, ex: described_class::CACHE_TTL)
      expect(service.generate("asset1")).to eq(:stored)
    end

    it "gets the thumbnail from the Contentful Images API, and not from the mirror" do
      stub_fetch

      service.generate("asset1")

      expect(URI).to have_received(:open).with(a_string_including("images.ctfassets.net"), any_args)
    end

    it "asks for a JPEG, thus libvips always has a loader for the answer" do
      stub_fetch

      service.generate("asset1")

      expect(URI).to have_received(:open).with(a_string_including("fm=jpg"), any_args)
    end

    it "does no work when the entry is already there" do
      allow($redis).to receive(:exists?).and_return(true)

      expect(service.generate("asset1")).to eq(:present)
      expect($redis).not_to have_received(:set)
    end

    it "skips a GIF, because it has no useful placeholder" do
      allow(contentful).to receive(:items).and_return([ asset.merge(contentType: "image/gif") ])

      expect(service.generate("asset1")).to eq(:skipped)
    end

    it "skips an asset with no dimensions" do
      allow(contentful).to receive(:items).and_return([ asset.merge(width: nil, height: nil) ])

      expect(service.generate("asset1")).to eq(:skipped)
    end

    it "skips an asset that Contentful does not give" do
      allow(contentful).to receive(:items).and_return([])

      expect(service.generate("asset1")).to eq(:skipped)
    end

    it "skips an asset that is not on the Images API host" do
      allow(contentful).to receive(:items)
        .and_return([ asset.merge(url: "https://downloads.ctfassets.net/space/a/t/f.jpg") ])

      expect(service.generate("asset1")).to eq(:skipped)
    end

    it "does not raise when the fetch fails, because a placeholder is decoration" do
      allow(URI).to receive(:open).and_raise(SocketError, "no")

      expect(service.generate("asset1")).to eq(:skipped)
    end

    it "skips a blank asset id" do
      expect(service.generate(nil)).to eq(:skipped)
    end
  end

  describe "#read" do
    it "reads one key" do
      allow($redis).to receive(:get).with("blurhash:svg:asset1:3").and_return("data:image/svg+xml,x")

      expect(service.read("asset1", 3)).to eq("data:image/svg+xml,x")
    end

    it "returns nil with no asset id or no version" do
      expect(service.read(nil, 3)).to be_nil
      expect(service.read("asset1", nil)).to be_nil
    end

    it "returns nil when Redis raises, thus the card renders with the flat colour" do
      allow($redis).to receive(:get).and_raise(Redis::BaseError, "down")

      expect(service.read("asset1", 3)).to be_nil
    end
  end

  describe "#backfill" do
    before do
      allow(contentful).to receive(:paginate).and_return([ { sys: { id: "a1" } }, { sys: { id: "a2" } } ])
    end

    it "adds one job for each asset" do
      expect { service.backfill }.to change(AssetBlurhashJob.jobs, :size).by(2)
    end

    it "adds no job for a dry run" do
      expect { service.backfill(dry_run: true) }.not_to change(AssetBlurhashJob.jobs, :size)
    end

    it "skips when the asset fetch fails" do
      allow(contentful).to receive(:paginate).and_return(nil)

      expect(service.backfill).to eq(:skipped)
    end
  end
end
