require "rails_helper"

RSpec.describe ContentfulManagement do
  subject(:cma) { described_class.new }

  let(:token) { "cma-token" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTENTFUL_SPACE").and_return("space123")
    allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return(token)
    allow(ENV).to receive(:[]).with("CONTENTFUL_ENVIRONMENT").and_return(nil)
  end

  def response_for(body, code: 200)
    instance_double(HTTParty::Response, success?: (200..299).cover?(code), code: code,
                                        body: body.is_a?(String) ? body : body.to_json,
                                        request: nil)
  end

  describe ".configured?" do
    it "needs the space and the management token" do
      expect(described_class).to be_configured

      allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return(nil)
      expect(described_class).not_to be_configured
    end
  end

  describe "#environment" do
    it "is master with no value, and the value when there is one" do
      expect(cma.environment).to eq("master")

      allow(ENV).to receive(:[]).with("CONTENTFUL_ENVIRONMENT").and_return("staging")
      expect(cma.environment).to eq("staging")
    end
  end

  describe "#create_upload" do
    let(:file) { Tempfile.new([ "media", ".jpg" ]).tap { |f| f.write("jpeg bytes"); f.flush } }

    after { file.close! }

    # ⚠️ It must stream from the disk. A `File.read` of a 38MB camera JPEG, three times over at
    # three Puma threads, is the shape of the OOM kill of the first R2 backfill.
    it "streams the file from the disk, with its length, and answers the upload id" do
      seen = nil
      allow(HTTParty).to receive(:post) do |_url, options|
        seen = options
        response_for({ sys: { id: "upload-1", type: "Upload" } })
      end

      expect(cma.create_upload(file.path)).to eq("upload-1")
      expect(HTTParty).to have_received(:post).with("https://upload.contentful.com/spaces/space123/uploads", anything)
      expect(seen[:body_stream]).to be_a(File)
      expect(seen).not_to have_key(:body)
      expect(seen[:headers]).to include(
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/octet-stream",
        "Content-Length" => File.size(file.path).to_s
      )
      expect(seen[:timeout]).to eq(described_class::UPLOAD_TIMEOUT_SECONDS)
    end

    it "raises for a result that is not a success" do
      allow(HTTParty).to receive(:post).and_return(response_for({ message: "nope" }, code: 401))

      expect { cma.create_upload(file.path) }.to raise_error(ApplicationService::HttpError)
    end

    # ⚠️ An upload that fails must not leave a file handle open. Three Puma threads that each lose
    # one would run the machine out of descriptors.
    it "closes the file even when the request raises" do
      handle = File.open(file.path, "rb")
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(file.path, "rb").and_return(handle)
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNRESET)

      expect { cma.create_upload(file.path) }.to raise_error(Errno::ECONNRESET)
      expect(handle).to be_closed
    end
  end

  describe "#create_asset" do
    it "posts the title, the description, and the link to the upload, in the default locale" do
      seen = nil
      allow(HTTParty).to receive(:post) do |_url, options|
        seen = options
        response_for({ sys: { id: "asset-1", version: 1 } })
      end

      result = cma.create_asset(title: "IMG_4821", description: "A dog running on a beach.",
                                file_name: "IMG_4821.jpg", content_type: "image/jpeg",
                                upload_id: "upload-1")

      expect(result).to eq(id: "asset-1", version: 1)
      expect(HTTParty).to have_received(:post)
        .with("https://api.contentful.com/spaces/space123/environments/master/assets", anything)
      expect(seen[:headers]).to include("Content-Type" => described_class::CONTENT_TYPE)
      expect(JSON.parse(seen[:body])).to eq(
        "fields" => {
          "title" => { "en-US" => "IMG_4821" },
          "description" => { "en-US" => "A dog running on a beach." },
          "file" => {
            "en-US" => {
              "contentType" => "image/jpeg",
              "fileName" => "IMG_4821.jpg",
              "uploadFrom" => { "sys" => { "type" => "Link", "linkType" => "Upload", "id" => "upload-1" } }
            }
          }
        }
      )
    end
  end

  describe "#process_asset" do
    # ⚠️ Contentful refuses a write whose version is not the current one.
    it "puts to the locale path with the version header" do
      allow(HTTParty).to receive(:put).and_return(response_for("", code: 204))

      cma.process_asset("asset-1", 1)

      expect(HTTParty).to have_received(:put).with(
        "https://api.contentful.com/spaces/space123/environments/master/assets/asset-1/files/en-US/process",
        hash_including(headers: hash_including("X-Contentful-Version" => "1"))
      )
    end
  end

  describe "#ensure_processed" do
    # ⚠️ This is what makes the job safe to run again: a retry after a failed publish must not ask
    # for a second processing.
    it "asks for no processing when the file already has a URL" do
      allow(HTTParty).to receive(:get).and_return(
        response_for({ sys: { version: 3 }, fields: { file: { "en-US": { url: "//images/x.jpg" } } } })
      )
      allow(HTTParty).to receive(:put)

      expect(cma.ensure_processed("asset-1")).to eq(3)
      expect(HTTParty).not_to have_received(:put)
    end

    it "processes and then waits when the file has no URL" do
      allow(cma).to receive(:sleep)
      allow(HTTParty).to receive(:put).and_return(response_for("", code: 204))
      allow(HTTParty).to receive(:get).and_return(
        response_for({ sys: { version: 1 }, fields: { file: { "en-US": {} } } }),
        response_for({ sys: { version: 2 }, fields: { file: { "en-US": { url: "//images/x.jpg" } } } })
      )

      expect(cma.ensure_processed("asset-1")).to eq(2)
      expect(HTTParty).to have_received(:put).once
    end
  end

  describe "#wait_for_processing" do
    it "raises when the processing does not end inside the timeout" do
      allow(cma).to receive(:sleep)
      allow(HTTParty).to receive(:get).and_return(response_for({ sys: { version: 1 }, fields: { file: { "en-US": {} } } }))
      # The deadline has passed already, thus the first read that finds no URL raises.
      allow(Time).to receive(:now).and_return(Time.at(0), Time.at(1_000))

      expect { cma.wait_for_processing("asset-1") }
        .to raise_error(/did not finish processing/)
    end
  end

  describe "#publish_asset" do
    it "puts to the published path with the version header" do
      allow(HTTParty).to receive(:put).and_return(response_for({ sys: { id: "asset-1", version: 3 } }))

      expect(cma.publish_asset("asset-1", 2)).to eq(id: "asset-1", version: 3)
      expect(HTTParty).to have_received(:put).with(
        "https://api.contentful.com/spaces/space123/environments/master/assets/asset-1/published",
        hash_including(headers: hash_including("X-Contentful-Version" => "2"))
      )
    end

    it "raises for a result that is not a success" do
      allow(HTTParty).to receive(:put).and_return(response_for({ message: "stale" }, code: 409))

      expect { cma.publish_asset("asset-1", 1) }.to raise_error(ApplicationService::HttpError)
    end
  end
end
