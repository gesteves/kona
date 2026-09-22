require "rails_helper"

RSpec.describe "Admin Contentful uploads", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("CONTENTFUL_SPACE").and_return("space123")
    allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return("cma-token")
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    $redis.del(UploadLibrary::REDIS_KEY)
  end

  after do
    $redis.del(UploadLibrary::REDIS_KEY)
    $redis.del(*@stored.map { |id| "#{StagedUpload::KEY_PREFIX}#{id}" }) if @stored.present?
  end

  def stage(file_name: "IMG_4821.jpg")
    id = StagedUpload.new.store(thumbnail: "\xFF\xD8\xFF\xE0jpeg".b, upload_id: "upload-1",
                                file_name: file_name, content_type: "image/jpeg", width: 2, height: 1)
    (@stored ||= []) << id
    id
  end

  describe "GET /contentful/uploads" do
    it "needs the owner session" do
      get "/contentful/uploads"

      expect(response).to redirect_to("/signin")
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      it "renders the picker and the empty state" do
        get "/contentful/uploads"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("wa-file-input")
        expect(response.body).to include(I18n.t("admin.contentful_uploads.index.empty"))
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      # The <template> renders the tile from the same partial that a stored tile uses, thus the
      # markup of a tile is in one place.
      it "renders the empty tile in a template, with the three field names" do
        get "/contentful/uploads"

        expect(response.body).to include("data-media-upload-target=\"fileTemplate\"")
        expect(response.body).to include('name="files[ids][]"')
        expect(response.body).to include('name="files[titles][]"')
        expect(response.body).to include('name="files[alts][]"')
      end

      it "says when there is no management token, and turns the picker off" do
        get "/contentful/uploads"
        picker = Nokogiri::HTML(response.body).at("wa-file-input")
        expect(picker["disabled"]).to be_nil

        allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return(nil)
        get "/contentful/uploads"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("CONTENTFUL_MANAGEMENT_TOKEN")
        expect(Nokogiri::HTML(response.body).at("wa-file-input")["disabled"]).not_to be_nil
      end

      # ⚠️ The Generate control renders with an Anthropic key alone, as the two other Claude
      # features stay silent without one.
      it "renders the Generate control only with an Anthropic key" do
        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
        get "/contentful/uploads"
        expect(response.body).not_to include(I18n.t("admin.contentful_uploads.file.generate_alt"))

        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
        get "/contentful/uploads"
        expect(response.body).to include(I18n.t("admin.contentful_uploads.file.generate_alt"))
      end

      it "lists a record with its status, and polls while one is processing" do
        UploadLibrary.new.stage(id: "a" * 32, title: "A photo", alt: "Words", file_name: "a.jpg")

        get "/contentful/uploads"

        expect(response.body).to include("A photo")
        expect(response.body).to include(I18n.t("admin.contentful_uploads.status.processing"))
        expect(response.body).to include('data-controller="job-status"')
        expect(response.body).to include("data-job-status-state=\"processing\"")
      end
    end
  end

  describe "POST /contentful/uploads" do
    it "needs the owner session" do
      post "/contentful/uploads", params: { files: { ids: [ stage ], titles: [ "A" ], alts: [ "B" ] } }

      expect(response).to redirect_to("/signin")
      expect(ContentfulAssetJob.jobs).to be_empty
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      it "records each tile and adds one job for each" do
        first = stage(file_name: "one.jpg")
        second = stage(file_name: "two.jpg")

        post "/contentful/uploads", params: { files: { ids: [ first, second ],
                                                       titles: [ "First", "Second" ],
                                                       alts: [ "A dog.", "A cat." ] } }

        expect(response).to redirect_to("/contentful/uploads")
        expect(response).to have_http_status(:see_other)
        expect(ContentfulAssetJob).to have_enqueued_sidekiq_job(first)
        expect(ContentfulAssetJob).to have_enqueued_sidekiq_job(second)

        library = UploadLibrary.new
        expect(library.find(first)).to include("title" => "First", "alt" => "A dog.",
                                               "file_name" => "one.jpg", "status" => "processing")
        expect(library.find(second)["title"]).to eq("Second")
      end

      # ⚠️ The three arrays match by POSITION. A drop of the id alone would move each title and
      # each alt text after it by one.
      it "drops a whole triple whose id has the wrong shape" do
        good = stage

        post "/contentful/uploads", params: { files: { ids: [ "", good ],
                                                       titles: [ "Lost", "Kept" ],
                                                       alts: [ "Wrong words", "Right words" ] } }

        expect(ContentfulAssetJob.jobs.size).to eq(1)
        expect(UploadLibrary.new.find(good)).to include("title" => "Kept", "alt" => "Right words")
      end

      it "says which tiles expired, and still takes the rest" do
        good = stage

        post "/contentful/uploads", params: { files: { ids: [ "0" * 32, good ],
                                                       titles: [ "Gone", "Kept" ],
                                                       alts: [ "", "" ] } }

        expect(ContentfulAssetJob.jobs.size).to eq(1)
        expect(flash[:alert]).to eq(I18n.t("admin.contentful_uploads.flash.expired", files: "Gone"))
        expect(flash[:notice]).to be_present
      end

      it "uses the file name when the owner emptied the title" do
        id = stage(file_name: "IMG_4821.jpg")

        post "/contentful/uploads", params: { files: { ids: [ id ], titles: [ "  " ], alts: [ "" ] } }

        expect(UploadLibrary.new.find(id)["title"]).to eq("IMG_4821")
      end

      it "refuses a submit with no tile" do
        post "/contentful/uploads", params: { files: { ids: [], titles: [], alts: [] } }

        expect(response).to redirect_to("/contentful/uploads")
        expect(flash[:alert]).to eq(I18n.t("admin.contentful_uploads.flash.no_files"))
        expect(ContentfulAssetJob.jobs).to be_empty
      end

      it "refuses a submit with more tiles than the limit" do
        ids = Array.new(Admin::ContentfulUploadsController::MAX_FILES + 1) { SecureRandom.hex(16) }

        post "/contentful/uploads", params: { files: { ids: ids, titles: ids, alts: ids } }

        expect(flash[:alert]).to eq(I18n.t("admin.contentful_uploads.flash.too_many",
                                           count: Admin::ContentfulUploadsController::MAX_FILES))
        expect(ContentfulAssetJob.jobs).to be_empty
      end

      it "refuses a submit with no management token" do
        allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return(nil)

        post "/contentful/uploads", params: { files: { ids: [ stage ], titles: [ "A" ], alts: [ "B" ] } }

        expect(flash[:alert]).to eq(I18n.t("admin.contentful_uploads.flash.unconfigured"))
        expect(ContentfulAssetJob.jobs).to be_empty
      end
    end
  end

  describe "GET /contentful/uploads/status" do
    it "needs the owner session" do
      get "/contentful/uploads/status"

      expect(response).to redirect_to("/signin")
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      # It answers the statuses and not the records: the page reads this each few seconds.
      it "answers the status of each record" do
        library = UploadLibrary.new
        library.stage(id: "a" * 32, title: "One", alt: "", file_name: "a.jpg")
        library.stage(id: "b" * 32, title: "Two", alt: "", file_name: "b.jpg")
        library.update("b" * 32, "status" => "published")

        get "/contentful/uploads/status", headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq("a" * 32 => "processing", "b" * 32 => "published")
      end
    end
  end
end
