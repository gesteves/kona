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

  # Says that the object is absent, if a test does not say another thing.
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
      .and_return(item.nil? ? [] : [ item ])
  end

  # The download uses a stream with Net::HTTP#read_body. Refer to AssetMirror#download for the
  # reason that it cannot use HTTParty. Thus the stub gives a true response object with a body in
  # parts.
  # @return [Array] The request URIs that the code under test got.
  def stub_download(body: "IMAGEBYTES", code: 200)
    requested = []
    klass = code == 200 ? Net::HTTPOK : Net::HTTPForbidden
    response = klass.new("1.1", code.to_s, "")
    allow(response).to receive(:read_body) { |&block| block.call(body) }

    http = instance_double(Net::HTTP)
    allow(http).to receive(:request) do |request, &block|
      requested << request.uri.to_s
      block.call(response)
    end
    allow(Net::HTTP).to receive(:start) { |*_args, **_opts, &block| block.call(http) }
    requested
  end

  # The same as stub_download, but the FIRST request answers with a 302 to `location` and each
  # request after it is a success. Thus the URIs in the result show if the code followed the
  # redirect or refused it.
  # @return [Array] The request URIs that the code got, in order.
  def stub_redirect(location, body: "IMAGEBYTES")
    requested = []

    redirect = Net::HTTPFound.new("1.1", "302", "")
    redirect["location"] = location

    ok = Net::HTTPOK.new("1.1", "200", "")
    allow(ok).to receive(:read_body) { |&block| block.call(body) }

    http = instance_double(Net::HTTP)
    allow(http).to receive(:request) do |request, &block|
      requested << request.uri.to_s
      block.call(requested.size == 1 ? redirect : ok)
    end
    allow(Net::HTTP).to receive(:start) { |*_args, **_opts, &block| block.call(http) }
    requested
  end

  before { stub_r2 }

  describe "#object_key" do
    # ⚠️ This is the contract between the two apps: web/lib/data/contentful.rb changes only the
    # host, thus the path that it writes must be the same as the key here. A change to one side
    # makes each image 404.
    it "is the Contentful path verbatim, minus the leading slash" do
      expect(mirror.object_key("https://images.ctfassets.net/space/asset1/token/photo.jpg")).to eq(key)
    end

    it "handles the protocol-relative URLs Contentful actually returns" do
      expect(mirror.object_key(asset_url)).to eq(key)
    end

    # ⚠️ Contentful serves some *image* assets from downloads.ctfassets.net. The two hosts are not
    # images and files. If the code matches only the images host, those assets go to Contentful for
    # all time, with no message, and this mirror exists to stop that. The path is the same on both
    # hosts, thus one key covers the asset from either host.
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
      expect(client).to receive(:put_object) do |args|
        expect(args).to include(bucket: "kona-images", key: key)
        expect(args[:body].read).to eq("IMAGEBYTES")
      end
      expect(mirror.sync("asset1")).to eq(:mirrored)
    end

    # ⚠️ This is necessary on a 512MB worker at concurrency 5: these originals are as large as 38MB,
    # and Strings that held them caused an OOM kill of the worker during a backfill. That kill loses
    # the jobs in progress with no message, because a hard kill is not a job failure that Sidekiq
    # can do again.
    it "streams to a file rather than buffering the body in memory" do
      body = nil
      allow(client).to receive(:put_object) { |args| body = args[:body] }
      mirror.sync("asset1")
      expect(body).to be_a(Tempfile)
    end

    # ⚠️ Without a content type, R2 serves application/octet-stream, and that stops both the browser
    # and Cloudflare Images.
    it "sets the content type and an immutable cache-control" do
      expect(client).to receive(:put_object).with(
        hash_including(content_type: "image/jpeg", cache_control: "public, max-age=31536000, immutable")
      )
      mirror.sync("asset1")
    end

    # This is what makes a second attempt and the backfill fast: a second run costs one HEAD and no
    # data transfer.
    it "skips the download and upload when the object is already there" do
      stub_client(exists: true)
      expect(client).not_to receive(:put_object)
      expect(Net::HTTP).not_to receive(:start)
      expect(mirror.sync("asset1")).to eq(:present)
    end

    it "skips an asset Contentful doesn't host" do
      stub_asset(url: "https://elsewhere.example.com/photo.jpg")
      expect(client).not_to receive(:put_object)
      expect(mirror.sync("asset1")).to eq(:skipped)
    end

    # The bytes come from the host that Contentful names. downloads.ctfassets.net has no Images API,
    # but it serves the original, and the mirror needs nothing more.
    it "downloads from the host Contentful gave, keyed on the shared path" do
      requested = stub_download
      stub_asset(url: "//downloads.ctfassets.net/space/asset1/token/photo.jpg")
      expect(client).to receive(:put_object).with(hash_including(key: key))
      mirror.sync("asset1")
      expect(requested).to eq([ "https://downloads.ctfassets.net/space/asset1/token/photo.jpg" ])
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

    # The raise is what makes Sidekiq do the job again. A smaller result here would leave a gap in
    # the mirror with no message, and that gap becomes a broken image.
    it "raises when the download fails" do
      stub_download(code: 503, body: "nope")
      expect { mirror.sync("asset1") }.to raise_error(ApplicationService::HttpError)
    end

    # ⚠️ The code writes the content that it gets to R2 at the key from ctfassets, and the public
    # image host serves it. Thus a redirect away from ctfassets would publish that content. A check
    # of the first URL only is not sufficient: the target of the redirect must also pass the same
    # list.
    it "refuses a redirect that leaves ctfassets rather than following it" do
      stub_redirect("http://169.254.169.254/latest/meta-data/")
      expect(client).not_to receive(:put_object)

      expect { mirror.sync("asset1") }
        .to raise_error(ArgumentError, /Refusing to mirror from http:\/\/169\.254\.169\.254/)
    end

    # A change from https to http is the second half of the same problem: an https source that
    # redirects to plain http on a host whose name only ends with ctfassets.net.
    it "refuses a redirect that downgrades to plain http" do
      stub_redirect("http://images.ctfassets.net/space/asset1/token/photo.jpg")
      expect(client).not_to receive(:put_object)

      expect { mirror.sync("asset1") }.to raise_error(ArgumentError, /Refusing to mirror from http:/)
    end

    it "still follows a redirect that stays on ctfassets" do
      target = "https://downloads.ctfassets.net/space/asset1/token/photo.jpg"
      requested = stub_redirect(target)
      expect(client).to receive(:put_object).with(hash_including(key: key))

      mirror.sync("asset1")

      expect(requested.last).to eq(target)
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
      stub_list([ { sys: { id: "asset1" } }, { sys: { id: "asset2" } } ])
      expect(mirror.backfill).to eq(2)
      expect(AssetSyncJob).to have_enqueued_sidekiq_job("asset1")
      expect(AssetSyncJob).to have_enqueued_sidekiq_job("asset2")
    end

    it "counts without enqueuing on a dry run" do
      stub_list([ { sys: { id: "asset1" } } ])
      expect(mirror.backfill(dry_run: true)).to eq(1)
      expect(AssetSyncJob.jobs).to be_empty
    end

    # An incomplete page would add too few jobs, with no message, and leave gaps that nothing else
    # would find.
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
