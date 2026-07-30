require "rails_helper"

describe AssetMirror do
  subject(:mirror) { described_class.new }

  let(:client) { instance_double(Aws::S3::Client) }
  let(:contentful) { instance_double(ContentfulClient) }
  let(:asset_url) { "//images.ctfassets.net/space/asset1/token/photo.jpg" }
  let(:key) { "space/asset1/token/photo.jpg" }

  def stub_r2(account: "acct", access_key: "key", secret: "secret", bucket: "kona-images")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("R2_ACCOUNT_ID").and_return(account)
    allow(ENV).to receive(:[]).with("R2_ACCESS_KEY_ID").and_return(access_key)
    allow(ENV).to receive(:[]).with("R2_SECRET_ACCESS_KEY").and_return(secret)
    allow(ENV).to receive(:[]).with("R2_BUCKET").and_return(bucket)
  end

  # Reports the object as absent unless a test says otherwise.
  def stub_client(exists: false)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:put_object)
    if exists
      allow(client).to receive(:head_object)
    else
      allow(client).to receive(:head_object).and_raise(Aws::S3::Errors::NotFound.new(nil, "not found"))
    end
  end

  def stub_asset(url: asset_url, content_type: "image/jpeg")
    allow(mirror).to receive(:contentful).and_return(contentful)
    item = url.nil? ? nil : { url: url, contentType: content_type }
    allow(contentful).to receive(:items)
      .with(described_class::ASSET_QUERY, { id: "asset1" }, collection: :assets)
      .and_return(item.nil? ? [] : [item])
  end

  def stub_download(body: "IMAGEBYTES", code: 200)
    response = instance_double(HTTParty::Response, success?: code == 200, code: code, body: body)
    allow(HTTParty).to receive(:get).and_return(response)
  end

  before { stub_r2 }

  describe "#object_key" do
    # ⚠️ The cross-app contract: web/lib/data/contentful.rb only swaps the host, so the path it
    # emits has to be exactly the key written here. Reshaping either side 404s every image.
    it "is the Contentful path verbatim, minus the leading slash" do
      expect(mirror.object_key("https://images.ctfassets.net/space/asset1/token/photo.jpg")).to eq(key)
    end

    it "handles the protocol-relative URLs Contentful actually returns" do
      expect(mirror.object_key(asset_url)).to eq(key)
    end

    # ⚠️ Contentful serves some *image* assets from downloads.ctfassets.net — it isn't an
    # images-vs-files split. Matching only the images host would silently leave those hitting
    # Contentful forever, which is the whole thing this mirror exists to stop. The path is
    # identical across hosts, so one key covers the asset either way.
    it "covers every ctfassets host, keyed on the same path" do
      expect(mirror.object_key("https://downloads.ctfassets.net/space/asset1/token/photo.jpg")).to eq(key)
      expect(mirror.object_key("https://assets.ctfassets.net/space/asset1/token/photo.jpg")).to eq(key)
    end

    it "is nil for a blank or foreign URL" do
      expect(mirror.object_key(nil)).to be_nil
      expect(mirror.object_key("https://elsewhere.example.com/photo.jpg")).to be_nil
    end
  end

  describe "#sync" do
    before do
      stub_client
      stub_asset
      stub_download
    end

    it "uploads the asset under its Contentful path" do
      expect(client).to receive(:put_object).with(hash_including(bucket: "kona-images", key: key, body: "IMAGEBYTES"))
      expect(mirror.sync("asset1")).to eq(:mirrored)
    end

    # ⚠️ Without an explicit content type R2 serves application/octet-stream, which breaks both
    # the browser and Cloudflare Images.
    it "sets the content type and an immutable cache-control" do
      expect(client).to receive(:put_object).with(
        hash_including(content_type: "image/jpeg", cache_control: "public, max-age=31536000, immutable")
      )
      mirror.sync("asset1")
    end

    # What makes retries and the backfill cheap: a re-run costs one HEAD and no transfer.
    it "skips the download and upload when the object is already there" do
      stub_client(exists: true)
      expect(client).not_to receive(:put_object)
      expect(HTTParty).not_to receive(:get)
      expect(mirror.sync("asset1")).to eq(:present)
    end

    it "skips an asset Contentful doesn't host" do
      stub_asset(url: "https://elsewhere.example.com/photo.jpg")
      expect(client).not_to receive(:put_object)
      expect(mirror.sync("asset1")).to eq(:skipped)
    end

    # The bytes come from whichever host Contentful named — downloads.ctfassets.net doesn't
    # support the Images API, but it serves the original just fine, which is all the mirror needs.
    it "downloads from the host Contentful gave, keyed on the shared path" do
      stub_asset(url: "//downloads.ctfassets.net/space/asset1/token/photo.jpg")
      expect(HTTParty).to receive(:get).with("https://downloads.ctfassets.net/space/asset1/token/photo.jpg")
        .and_return(instance_double(HTTParty::Response, success?: true, code: 200, body: "IMAGEBYTES"))
      expect(client).to receive(:put_object).with(hash_including(key: key))
      mirror.sync("asset1")
    end

    it "skips an asset Contentful has no published record of" do
      stub_asset(url: nil)
      expect(client).not_to receive(:put_object)
      expect(mirror.sync("asset1")).to eq(:skipped)
    end

    it "no-ops when R2 is unconfigured, rather than failing the webhook path" do
      stub_r2(bucket: nil)
      expect(mirror.sync("asset1")).to eq(:skipped)
    end

    # The raise is what buys Sidekiq's retry; degrading here would leave a silent hole in the
    # mirror that surfaces as a broken image.
    it "raises when the download fails" do
      stub_download(code: 503, body: "nope")
      expect { mirror.sync("asset1") }.to raise_error(ApplicationService::HttpError)
    end
  end

  describe "#backfill" do
    before do
      stub_client
      allow(mirror).to receive(:contentful).and_return(contentful)
    end

    def stub_list(items)
      allow(contentful).to receive(:paginate)
        .with(described_class::ASSETS_LIST_QUERY, collection: :assets, strict: true)
        .and_return(items)
    end

    it "enqueues a sync job per asset" do
      stub_list([{ sys: { id: "asset1" } }, { sys: { id: "asset2" } }])
      expect(mirror.backfill).to eq(2)
      expect(AssetSyncJob).to have_enqueued_sidekiq_job("asset1")
      expect(AssetSyncJob).to have_enqueued_sidekiq_job("asset2")
    end

    it "counts without enqueuing on a dry run" do
      stub_list([{ sys: { id: "asset1" } }])
      expect(mirror.backfill(dry_run: true)).to eq(1)
      expect(AssetSyncJob.jobs).to be_empty
    end

    # A partial page would silently under-enqueue and leave holes nothing else would find.
    it "enqueues nothing when the asset fetch fails" do
      stub_list(nil)
      expect(mirror.backfill).to eq(:skipped)
      expect(AssetSyncJob.jobs).to be_empty
    end

    it "no-ops when R2 is unconfigured" do
      stub_r2(account: nil)
      expect(mirror.backfill).to eq(:skipped)
      expect(AssetSyncJob.jobs).to be_empty
    end
  end
end
