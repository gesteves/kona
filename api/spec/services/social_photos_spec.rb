require "rails_helper"

RSpec.describe SocialPhotos do
  subject(:store) { described_class.new }

  let(:jpeg) { "\xFF\xD8\xFF\xE0binary\x00bytes".b }
  let!(:id) { store.store(image: jpeg, width: 640, height: 480) }

  after { $redis.del("#{described_class::KEY_PREFIX}#{id}") }

  it "makes an id of the shape that it accepts" do
    expect(id).to match(described_class::ID_PATTERN)
    expect(described_class.id?(id)).to be(true)
    expect(described_class.id?("../etc")).to be(false)
    expect(described_class.id?(nil)).to be(false)
  end

  # ⚠️ redis-rb tags each string UTF-8, and a JPEG with that tag is an invalid string.
  it "gives the bytes back as binary, with the size in pixels" do
    photo = store.fetch(id)

    expect(photo[:image]).to eq(jpeg)
    expect(photo[:image].encoding).to eq(Encoding::BINARY)
    expect(photo[:width]).to eq(640)
    expect(photo[:height]).to eq(480)
  end

  it "gives each photo the draft TTL" do
    expect($redis.ttl("#{described_class::KEY_PREFIX}#{id}")).to be_within(5).of(described_class::DRAFT_TTL.to_i)
  end

  it "answers nil and false for a photo that is absent, and for an id with the wrong shape" do
    expect(store.fetch("0" * 32)).to be_nil
    expect(store.fetch("nope")).to be_nil
    expect(store.exists?(id)).to be(true)
    expect(store.exists?("0" * 32)).to be(false)
  end

  it "keeps a photo for longer" do
    store.keep([ id, "nope" ], 90_000)

    expect($redis.ttl("#{described_class::KEY_PREFIX}#{id}")).to be_within(5).of(90_000)
  end

  it "discards a photo" do
    store.discard([ id ])

    expect(store.exists?(id)).to be(false)
  end

  describe ".public_url" do
    before { allow(ENV).to receive(:[]).and_call_original }

    it "gives a signed URL on the public API host" do
      allow(ENV).to receive(:[]).with("API_HOST").and_return("api.example.test")

      expect(described_class.public_url(id))
        .to eq("https://api.example.test/api/social-photos/#{id}/#{described_class.signature(id)}")
    end

    # ⚠️ Meta cannot GET a local URL, thus the job must fail for good and not retry for a day.
    it "raises a permanent error with no API_HOST" do
      allow(ENV).to receive(:[]).with("API_HOST").and_return(nil)

      expect { described_class.public_url(id) }.to raise_error(ApplicationJob::PermanentError, /API_HOST/)
    end
  end

  describe ".valid_signature?" do
    it "accepts the signature of the id, and refuses each other value" do
      signature = described_class.signature(id)

      expect(signature).to match(described_class::SIGNATURE_PATTERN)
      expect(described_class.valid_signature?(id, signature)).to be(true)
      expect(described_class.valid_signature?(id, signature.reverse)).to be(false)
      expect(described_class.valid_signature?(id, "")).to be(false)
      expect(described_class.valid_signature?("../etc", signature)).to be(false)
    end
  end
end
