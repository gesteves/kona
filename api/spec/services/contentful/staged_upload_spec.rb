require "rails_helper"

RSpec.describe StagedUpload do
  subject(:store) { described_class.new }

  let(:jpeg) { "\xFF\xD8\xFF\xE0jpeg".b }

  after { $redis.del(*@stored.map { |id| "#{described_class::KEY_PREFIX}#{id}" }) if @stored.present? }

  def stage(**overrides)
    id = store.store(**{ thumbnail: jpeg, upload_id: "upload-1", file_name: "IMG_4821.jpg",
                         content_type: "image/jpeg", width: 2, height: 1 }.merge(overrides))
    (@stored ||= []) << id
    id
  end

  describe ".id?" do
    it "takes 32 hex characters only" do
      expect(described_class.id?("a" * 32)).to be(true)
      expect(described_class.id?("a" * 31)).to be(false)
      expect(described_class.id?("not-an-id")).to be(false)
      expect(described_class.id?(nil)).to be(false)
      expect(described_class.id?(:symbol)).to be(false)
    end
  end

  describe "#store" do
    it "makes an id and gives the key a TTL" do
      id = stage

      expect(id).to match(described_class::ID_PATTERN)
      expect($redis.ttl("#{described_class::KEY_PREFIX}#{id}"))
        .to be_within(5).of(described_class::TTL.to_i)
    end

    # ⚠️ An Upload of Contentful is retained for 24 hours, thus this TTL must stay below that.
    it "expires well before the Upload of Contentful does" do
      expect(described_class::TTL).to be < 24.hours
    end
  end

  describe "#fetch" do
    it "gives the record back, with the numbers as integers" do
      id = stage

      expect(store.fetch(id)).to eq(thumbnail: jpeg, upload_id: "upload-1", file_name: "IMG_4821.jpg",
                                    content_type: "image/jpeg", width: 2, height: 1)
    end

    # ⚠️ redis-rb tags each string UTF-8. A JPEG with that tag is an invalid string, and a later
    # step that reads it as text raises.
    it "gives the thumbnail as binary" do
      expect(store.fetch(stage)[:thumbnail].encoding).to eq(Encoding::BINARY)
    end

    it "gives nil for a file that is gone and for an id with the wrong shape" do
      expect(store.fetch("0" * 32)).to be_nil
      expect(store.fetch("not-an-id")).to be_nil
    end
  end

  describe "#exists? and #discard" do
    it "says whether a file is there, and removes it" do
      id = stage
      expect(store.exists?(id)).to be(true)

      store.discard([ id ])
      expect(store.exists?(id)).to be(false)
    end

    it "removes nothing for a list with no correct id" do
      expect { store.discard([ "not-an-id", nil ]) }.not_to raise_error
    end
  end
end
