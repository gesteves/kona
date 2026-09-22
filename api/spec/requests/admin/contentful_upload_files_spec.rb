require "rails_helper"
require "vips"

RSpec.describe "Admin Contentful upload files", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:contentful) { instance_double(ContentfulManagement) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("CONTENTFUL_SPACE").and_return("space123")
    allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return("cma-token")
    allow(ContentfulManagement).to receive(:new).and_return(contentful)
    allow(contentful).to receive(:create_upload).and_return("upload-1")
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  after { $redis.del(*@stored.map { |id| "#{StagedUpload::KEY_PREFIX}#{id}" }) if @stored.present? }

  # A PNG of one colour, on the disk, as an upload.
  def upload(width = 30, height = 10, name: "IMG_4821.png")
    file = Tempfile.new([ "media", ".png" ])
    file.binmode
    file.write((Vips::Image.black(width, height, bands: 3).copy(interpretation: :srgb) + [ 10, 120, 200 ]).cast(:uchar).write_to_buffer(".png"))
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: name)
  end

  def remember(id)
    (@stored ||= []) << id
    id
  end

  def stage(file_name: "IMG_4821.jpg", content_type: "image/jpeg")
    remember(StagedUpload.new.store(thumbnail: "\xFF\xD8\xFF\xE0jpeg".b, upload_id: "upload-1",
                                    file_name: file_name, content_type: content_type,
                                    width: 2, height: 1))
  end

  describe "POST /contentful/uploads/files" do
    it "needs the owner session" do
      post "/contentful/uploads/files", params: { file: upload }

      expect(response).to redirect_to("/signin")
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      it "stages the file and answers with its id, its two paths, and its title" do
        post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        answer = JSON.parse(response.body)
        id = remember(answer["id"])
        expect(id).to match(StagedUpload::ID_PATTERN)
        expect(answer["path"]).to eq("/contentful/uploads/files/#{id}")
        expect(answer["alt_path"]).to eq("/contentful/uploads/files/#{id}/alt")
        # ⚠️ The title is the name with NO extension.
        expect(answer["title"]).to eq("IMG_4821")
        expect($redis.ttl("#{StagedUpload::KEY_PREFIX}#{id}")).to be_within(5).of(StagedUpload::TTL.to_i)
      end

      # ⚠️ Contentful gets the ORIGINAL file, and the thumbnail is only for the tile and for
      # Claude. A resize of the asset would lose the resolution that the site needs.
      it "sends the original file to Contentful, and keeps a smaller thumbnail" do
        post "/contentful/uploads/files", params: { file: upload(4000, 3000) },
                                          headers: { "Accept" => "application/json" }

        id = remember(JSON.parse(response.body)["id"])
        expect(contentful).to have_received(:create_upload)
        staged = StagedUpload.new.fetch(id)
        expect(staged[:upload_id]).to eq("upload-1")
        expect(staged[:width]).to eq(PhotoBlob::THUMBNAIL_EDGE)
        expect(staged[:file_name]).to eq("IMG_4821.png")
      end

      # ⚠️ **The upload stays on the disk.** Both steps read the temporary file of Puma, thus a
      # 50MB photo does not go into the Ruby heap of a 512MB machine at three Puma threads.
      it "gives both steps the path of the file, and never its bytes" do
        # ⚠️ It reads each argument DURING the call. Rack unlinks the temporary file of the upload
        # at the end of the request, thus a check after it would find no file whatever the action
        # gave.
        seen = {}
        allow(PhotoBlob).to receive(:thumbnail).and_wrap_original do |original, argument, **options|
          seen[:thumbnail] = argument.is_a?(String) && File.exist?(argument)
          original.call(argument, **options)
        end
        allow(contentful).to receive(:create_upload) do |argument|
          seen[:upload] = argument.is_a?(String) && File.exist?(argument)
          "upload-1"
        end

        post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }
        remember(JSON.parse(response.body)["id"])

        expect(seen[:thumbnail]).to be(true), "the action did not give PhotoBlob the path of the upload"
        expect(seen[:upload]).to be(true), "the action did not give Contentful the path of the upload"
      end

      it "refuses a request with no file" do
        post "/contentful/uploads/files", params: {}, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.contentful_uploads.files.no_file"))
      end

      # ⚠️ The decode is the check, and it runs BEFORE the app sends one byte to Contentful. A
      # content type from the browser proves nothing.
      it "refuses a file that is not a picture before it reaches Contentful" do
        file = Tempfile.new([ "words", ".png" ])
        file.write("these are words and not a picture")
        file.rewind

        post "/contentful/uploads/files", params: { file: Rack::Test::UploadedFile.new(file.path, "image/png") },
                                          headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.contentful_uploads.files.not_an_image"))
        expect(contentful).not_to have_received(:create_upload)
      end

      it "refuses a file above the limit before it reads it" do
        allow_any_instance_of(ActionDispatch::Http::UploadedFile).to receive(:size)
          .and_return(Admin::ContentfulUploadFilesController::MAX_BYTES + 1)
        allow(PhotoBlob).to receive(:thumbnail)

        post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content)
        limit = ActiveSupport::NumberHelper.number_to_human_size(Admin::ContentfulUploadFilesController::MAX_BYTES)
        expect(JSON.parse(response.body)["error"]).to start_with(t_before("admin.contentful_uploads.files.too_large", :size, limit: limit))
        expect(PhotoBlob).not_to have_received(:thumbnail)
      end

      it "says when there is no management token, and reads nothing" do
        allow(ENV).to receive(:[]).with("CONTENTFUL_MANAGEMENT_TOKEN").and_return(nil)
        allow(PhotoBlob).to receive(:thumbnail)

        post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:service_unavailable)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.contentful_uploads.files.unconfigured"))
        expect(PhotoBlob).not_to have_received(:thumbnail)
      end

      it "says when Contentful refused the bytes, and stages nothing" do
        allow(contentful).to receive(:create_upload).and_raise(ApplicationService::HttpError.new(401, "nope", "url"))
        allow(ErrorReporter).to receive(:report_upstream)

        post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:bad_gateway)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.contentful_uploads.files.upload_refused"))
        expect(ErrorReporter).to have_received(:report_upstream)
      end

      it "does not store the answer" do
        post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }
        remember(JSON.parse(response.body)["id"])

        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      # ⚠️ The admin does not skip the forgery protection, and `media_upload_controller.js` sends
      # the token in a header. The test environment turns that protection off, thus this one
      # turns it on.
      context "when the forgery protection is on" do
        around do |example|
          was = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          example.run
          ActionController::Base.allow_forgery_protection = was
        end

        it "takes the token of the page in a header, and refuses the request without it" do
          get "/contentful/uploads"
          token = Nokogiri::HTML(response.body).at("meta[name=csrf-token]")&.[]("content")
          expect(token).to be_present

          post "/contentful/uploads/files", params: { file: upload },
                                            headers: { "Accept" => "application/json", "X-CSRF-Token" => token }
          expect(response).to have_http_status(:ok)
          remember(JSON.parse(response.body)["id"])

          post "/contentful/uploads/files", params: { file: upload }, headers: { "Accept" => "application/json" }
          expect(response).not_to have_http_status(:ok)
        end
      end
    end
  end

  describe "GET /contentful/uploads/files/:id" do
    let(:id) { stage }

    it "needs the owner session" do
      get "/contentful/uploads/files/#{id}"

      expect(response).to redirect_to("/signin")
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      it "sends the thumbnail inline, and does not store the answer" do
        get "/contentful/uploads/files/#{id}"

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("image/jpeg")
        expect(response.headers["Content-Disposition"]).to start_with("inline")
        expect(response.headers["Cache-Control"]).to include("no-store")
        expect(response.body.b).to eq("\xFF\xD8\xFF\xE0jpeg".b)
      end

      it "answers 404 for a file that is gone" do
        get "/contentful/uploads/files/#{'0' * 32}"

        expect(response).to have_http_status(:not_found)
      end

      it "answers 404 for an id with the wrong shape" do
        get "/contentful/uploads/files/not-an-id"

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /contentful/uploads/files/:id/alt" do
    let(:jpeg) { "\xFF\xD8\xFF\xE0jpeg".b }
    let(:id) { stage }

    before do
      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
      allow(AltText).to receive(:generate).and_return("A dog running on a beach.")
    end

    it "needs the owner session" do
      post "/contentful/uploads/files/#{id}/alt"

      expect(response).to redirect_to("/signin")
      expect(AltText).not_to have_received(:generate)
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      # ⚠️ It sends the THUMBNAIL, and not the original: a 38MB camera JPEG as base64 is far past
      # what the call should carry.
      it "asks Claude about the thumbnail and answers with the alt text" do
        post "/contentful/uploads/files/#{id}/alt", headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq("alt" => "A dog running on a beach.")
        expect(AltText).to have_received(:generate).with(image: jpeg)
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      it "answers 404 for a file that is gone, and asks nothing" do
        post "/contentful/uploads/files/#{'0' * 32}/alt", headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:not_found)
        expect(AltText).not_to have_received(:generate)
      end

      it "says when there is no API key, and asks nothing" do
        allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)

        post "/contentful/uploads/files/#{id}/alt", headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:service_unavailable)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.contentful_uploads.files.alt_not_configured"))
        expect(AltText).not_to have_received(:generate)
      end

      it "says when Claude gave no answer" do
        allow(AltText).to receive(:generate).and_return(nil)

        post "/contentful/uploads/files/#{id}/alt", headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:bad_gateway)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.contentful_uploads.files.alt_failed"))
      end
    end
  end
end
