require "rails_helper"

RSpec.describe MapboxTileset do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAPBOX_USERNAME").and_return("testuser")
    allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return("sk.test-token")
  end

  def response(success:, code: 200, body: "{}")
    instance_double(HTTParty::Response, success?: success, code: code, body: body)
  end

  describe ".configured?" do
    it "is true with a username and a secret token" do
      expect(described_class).to be_configured
    end

    it "is false without them, so dev and CI stay inert" do
      allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return(nil)

      expect(described_class).not_to be_configured
    end
  end

  describe "#initialize" do
    it "refuses to run without a username" do
      allow(ENV).to receive(:[]).with("MAPBOX_USERNAME").and_return(nil)

      expect { described_class.new }.to raise_error(described_class::ConfigurationError, /MAPBOX_USERNAME/)
    end

    it "refuses to run without a secret token" do
      allow(ENV).to receive(:[]).with("MAPBOX_SECRET_TOKEN").and_return(nil)

      expect { described_class.new }.to raise_error(described_class::ConfigurationError, /MAPBOX_SECRET_TOKEN/)
    end
  end

  describe "#find" do
    it "returns the full id and source layer of a published tileset" do
      allow(HTTParty).to receive(:get).and_return(
        response(success: true, body: { vector_layers: [ { id: "track" } ] }.to_json)
      )

      expect(described_class.new.find("abc")).to eq([ "testuser.abc", "track" ])
      expect(HTTParty).to have_received(:get).with(
        "https://api.mapbox.com/v4/testuser.abc.json",
        query: { access_token: "sk.test-token" },
        timeout: 30
      )
    end

    it "is nil when the tileset doesn't exist" do
      allow(HTTParty).to receive(:get).and_return(response(success: false, code: 404))

      expect(described_class.new.find("abc")).to be_nil
    end

    it "is nil when the tileset has no renderable layer" do
      allow(HTTParty).to receive(:get).and_return(response(success: true, body: { vector_layers: [] }.to_json))

      expect(described_class.new.find("abc")).to be_nil
    end

    it "is nil rather than raising on a body that isn't JSON" do
      allow(HTTParty).to receive(:get).and_return(response(success: true, body: "<html>"))

      expect(described_class.new.find("abc")).to be_nil
    end
  end

  describe "#create_from_coordinates!" do
    let(:coordinates) { [ [ 10.0, 50.0 ], [ 11.0, 51.0 ] ] }

    before do
      allow(HTTParty).to receive(:put).and_return(response(success: true))
      allow(HTTParty).to receive(:post).and_return(
        response(success: true), # create
        response(success: true, body: { jobId: "job-1" }.to_json) # publish
      )
      allow(HTTParty).to receive(:get).and_return(response(success: true, body: { stage: "success" }.to_json))
    end

    it "uploads, creates, publishes, waits, and returns the full id" do
      result = described_class.new.create_from_coordinates!(id: "abc", name: "A Ride", coordinates: coordinates)

      expect(result).to eq("testuser.abc")
    end

    # ⚠️ PUT, not POST: POST appends to an existing source, which would accumulate stale tracks.
    it "replaces the source rather than appending to it" do
      described_class.new.create_from_coordinates!(id: "abc", name: "A Ride", coordinates: coordinates)

      expect(HTTParty).to have_received(:put).with(
        "https://api.mapbox.com/tilesets/v1/sources/testuser/abc", hash_including(multipart: true)
      )
    end

    it "treats an existing tileset as success, so a retry finishes the job" do
      allow(HTTParty).to receive(:post).and_return(
        response(success: false, code: 422, body: { message: "Tileset already exists" }.to_json),
        response(success: true, body: { jobId: "job-1" }.to_json)
      )

      expect { described_class.new.create_from_coordinates!(id: "abc", name: "A Ride", coordinates: coordinates) }
        .not_to raise_error
    end

    it "raises when the publish job fails" do
      allow(HTTParty).to receive(:get).and_return(
        response(success: true, body: { stage: "failed", errors: [ "bad geometry" ] }.to_json)
      )

      expect { described_class.new.create_from_coordinates!(id: "abc", name: "A Ride", coordinates: coordinates) }
        .to raise_error(/bad geometry/)
    end

    it "surfaces Mapbox's message when the upload is refused" do
      allow(HTTParty).to receive(:put).and_return(
        response(success: false, code: 401, body: { message: "Not authorized" }.to_json)
      )

      expect { described_class.new.create_from_coordinates!(id: "abc", name: "A Ride", coordinates: coordinates) }
        .to raise_error(/upload tileset source: Not authorized/)
    end
  end

  describe "#destroy!" do
    # ⚠️ Both, deliberately: deleting only the tileset orphans its source, which still counts
    # against the account and is invisible in the tileset list.
    it "removes the tileset and its source" do
      allow(HTTParty).to receive(:delete).and_return(response(success: true))

      described_class.new.destroy!("abc")

      expect(HTTParty).to have_received(:delete).with("https://api.mapbox.com/tilesets/v1/testuser.abc", anything)
      expect(HTTParty).to have_received(:delete).with("https://api.mapbox.com/tilesets/v1/sources/testuser/abc", anything)
    end

    it "treats an already-missing tileset as deleted" do
      allow(HTTParty).to receive(:delete).and_return(response(success: false, code: 404))

      expect { described_class.new.destroy!("abc") }.not_to raise_error
    end

    it "raises on anything else, so the local record isn't dropped while the remote one survives" do
      allow(HTTParty).to receive(:delete).and_return(
        response(success: false, code: 403, body: { message: "Forbidden" }.to_json)
      )

      expect { described_class.new.destroy!("abc") }.to raise_error(/delete tileset: Forbidden/)
    end
  end

  describe "tileset names" do
    it "transliterates and trims to Mapbox's allowed set" do
      allow(HTTParty).to receive(:put).and_return(response(success: true))
      allow(HTTParty).to receive(:post).and_return(
        response(success: true), response(success: true, body: { jobId: "j" }.to_json)
      )
      allow(HTTParty).to receive(:get).and_return(response(success: true, body: { stage: "success" }.to_json))

      described_class.new.create_from_coordinates!(id: "abc", name: "Cœur d'Alène — 70.3!", coordinates: [ [ 1, 2 ] ])

      expect(HTTParty).to have_received(:post).with(
        "https://api.mapbox.com/tilesets/v1/testuser.abc",
        hash_including(body: include('"name":"Coeur dAlene 70.3"'))
      )
    end
  end
end
