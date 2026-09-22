require "rails_helper"

RSpec.describe ContentfulAssetJob do
  let(:library) { UploadLibrary.new }
  let(:staged) { StagedUpload.new }
  let(:contentful) { instance_double(ContentfulManagement) }
  let(:id) { SecureRandom.hex(16) }

  before do
    $redis.del(UploadLibrary::REDIS_KEY)
    # ⚠️ `StagedUpload#store` makes its own id, and the record of the library must carry the SAME
    # one. Thus this spec writes the staged key directly, with the id that it controls.
    $redis.hset("#{StagedUpload::KEY_PREFIX}#{id}", "thumbnail", "\xFF\xD8\xFF\xE0jpeg".b,
                "upload_id", "upload-1", "file_name", "IMG_4821.jpg",
                "content_type", "image/jpeg", "width", 2, "height", 1)
    library.stage(id: id, title: "IMG_4821", alt: "A dog running on a beach.", file_name: "IMG_4821.jpg")

    allow(ContentfulManagement).to receive(:new).and_return(contentful)
    allow(contentful).to receive(:create_asset).and_return({ id: "asset-1", version: 1 })
    allow(contentful).to receive(:ensure_processed).and_return(2)
    allow(contentful).to receive(:publish_asset).and_return({ id: "asset-1", version: 3 })
  end

  after do
    $redis.del(UploadLibrary::REDIS_KEY)
    $redis.del("#{StagedUpload::KEY_PREFIX}#{id}")
  end

  it "creates, processes, and publishes the asset, then records it" do
    described_class.new.perform(id)

    expect(contentful).to have_received(:create_asset).with(
      title: "IMG_4821", description: "A dog running on a beach.",
      file_name: "IMG_4821.jpg", content_type: "image/jpeg", upload_id: "upload-1"
    )
    expect(contentful).to have_received(:ensure_processed).with("asset-1")
    expect(contentful).to have_received(:publish_asset).with("asset-1", 2)

    record = library.find(id)
    expect(record["status"]).to eq("published")
    expect(record["asset_id"]).to eq("asset-1")
    expect(record["error"]).to be_nil
  end

  it "discards the staged file after the publish" do
    described_class.new.perform(id)

    expect(staged.fetch(id)).to be_nil
  end

  # ⚠️ The record keeps the asset id BEFORE the process call. A retry that created a second asset
  # would leave a duplicate in the space, unpublished, with no message.
  it "writes the asset id before it processes the file" do
    seen = nil
    allow(contentful).to receive(:ensure_processed) do
      seen = library.find(id)["asset_id"]
      2
    end

    described_class.new.perform(id)

    expect(seen).to eq("asset-1")
  end

  it "creates no second asset when a retry finds one in the record" do
    library.update(id, "asset_id" => "asset-1")

    described_class.new.perform(id)

    expect(contentful).not_to have_received(:create_asset)
    expect(contentful).to have_received(:ensure_processed).with("asset-1")
    expect(library.find(id)["status"]).to eq("published")
  end

  it "does nothing for a record that is published already" do
    library.update(id, "status" => "published")

    described_class.new.perform(id)

    expect(contentful).not_to have_received(:create_asset)
  end

  it "does nothing for a record that is gone" do
    library.delete(id)

    described_class.new.perform(id)

    expect(contentful).not_to have_received(:create_asset)
  end

  # ⚠️ PermanentError and not a plain raise: the Upload of Contentful is gone with the staged
  # record, thus no later attempt can find the bytes.
  it "fails permanently when the staged file expired" do
    $redis.del("#{StagedUpload::KEY_PREFIX}#{id}")

    expect { described_class.new.perform(id) }.to raise_error(ApplicationJob::PermanentError)
    expect(contentful).not_to have_received(:create_asset)
  end

  it "raises on an upstream failure, thus Sidekiq does the job again" do
    allow(contentful).to receive(:publish_asset).and_raise(ApplicationService::HttpError.new(409, "stale", "url"))

    expect { described_class.new.perform(id) }.to raise_error(ApplicationService::HttpError)
    # ⚠️ The record stays at "processing": a mark of "failed" at the first exception would change
    # it between failed and processing at each attempt.
    expect(library.find(id)["status"]).to eq("processing")
  end

  describe "when Sidekiq gives up" do
    it "records the failure and its reason" do
      described_class.sidekiq_retries_exhausted_block.call(
        { "args" => [ id ] }, ApplicationService::HttpError.new(409, "stale", "url")
      )

      record = library.find(id)
      expect(record["status"]).to eq("failed")
      expect(record["error"]).to include("409")
    end
  end
end
