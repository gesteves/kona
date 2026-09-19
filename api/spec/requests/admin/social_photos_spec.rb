require "rails_helper"
require "vips"

RSpec.describe "Admin social photos", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
  end

  after { $redis.del(*@stored.map { |id| "#{SocialPhotos::KEY_PREFIX}#{id}" }) if @stored.present? }

  # A PNG of one colour, on the disk, as an upload.
  def upload(width = 30, height = 10, name: "photo.png")
    file = Tempfile.new([ "photo", ".png" ])
    file.binmode
    file.write((Vips::Image.black(width, height, bands: 3).copy(interpretation: :srgb) + [ 10, 120, 200 ]).cast(:uchar).write_to_buffer(".png"))
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: name)
  end

  def remember(id)
    (@stored ||= []) << id
    id
  end

  describe "POST /social/photos" do
    it "needs the owner session" do
      post "/social/photos", params: { photo: upload }

      expect(response).to redirect_to("/signin")
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      it "stores the photo and answers with its id, its path, and its size" do
        post "/social/photos", params: { photo: upload }, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:ok)
        answer = JSON.parse(response.body)
        id = remember(answer["id"])
        expect(id).to match(SocialPhotos::ID_PATTERN)
        expect(answer["path"]).to eq("/social/photos/#{id}")
        expect(answer["width"]).to eq(30)
        expect(answer["height"]).to eq(10)
        expect($redis.ttl("#{SocialPhotos::KEY_PREFIX}#{id}")).to be_within(5).of(SocialPhotos::DRAFT_TTL.to_i)
      end

      it "refuses a request with no file" do
        post "/social/photos", params: {}, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.social.photos.no_file"))
      end

      # ⚠️ The decode is the check. A content type from the browser proves nothing.
      it "refuses a file that is not a picture, whatever its content type says" do
        file = Tempfile.new([ "words", ".png" ])
        file.write("these are words and not a picture")
        file.rewind

        post "/social/photos", params: { photo: Rack::Test::UploadedFile.new(file.path, "image/png") },
                               headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq(I18n.t("admin.social.photos.not_an_image"))
      end

      it "refuses a file above the limit before it reads it" do
        allow_any_instance_of(ActionDispatch::Http::UploadedFile).to receive(:size)
          .and_return(Admin::SocialPhotosController::MAX_BYTES + 1)
        allow(PhotoBlob).to receive(:prepare)

        post "/social/photos", params: { photo: upload }, headers: { "Accept" => "application/json" }

        expect(response).to have_http_status(:unprocessable_content)
        limit = ActiveSupport::NumberHelper.number_to_human_size(Admin::SocialPhotosController::MAX_BYTES)
        expect(JSON.parse(response.body)["error"]).to start_with(t_before("admin.social.photos.too_large", :size, limit: limit))
        expect(PhotoBlob).not_to have_received(:prepare)
      end

      it "does not store the answer" do
        post "/social/photos", params: { photo: upload }, headers: { "Accept" => "application/json" }
        remember(JSON.parse(response.body)["id"])

        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      # ⚠️ The admin does not skip the forgery protection, and `social_post_controller.js` sends
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
          get "/social"
          token = Nokogiri::HTML(response.body).at("meta[name=csrf-token]")&.[]("content")
          expect(token).to be_present

          post "/social/photos", params: { photo: upload },
                                 headers: { "Accept" => "application/json", "X-CSRF-Token" => token }
          expect(response).to have_http_status(:ok)
          remember(JSON.parse(response.body)["id"])

          post "/social/photos", params: { photo: upload }, headers: { "Accept" => "application/json" }
          expect(response).not_to have_http_status(:ok)
        end
      end
    end
  end

  describe "GET /social/photos/:id" do
    let(:id) { remember(SocialPhotos.new.store(image: "\xFF\xD8\xFF\xE0jpeg".b, width: 2, height: 1)) }

    it "needs the owner session" do
      get "/social/photos/#{id}"

      expect(response).to redirect_to("/signin")
    end

    context "when the owner is signed in" do
      before { sign_in_as(email: owner_email) }

      # ⚠️ It is the same bytes that go up as the blob, thus the tile shows what the post will hold.
      it "sends the stored JPEG inline, and does not store the answer" do
        get "/social/photos/#{id}"

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("image/jpeg")
        expect(response.headers["Content-Disposition"]).to start_with("inline")
        expect(response.headers["Cache-Control"]).to include("no-store")
        expect(response.body.b).to eq("\xFF\xD8\xFF\xE0jpeg".b)
      end

      it "answers 404 for a photo that is gone" do
        get "/social/photos/#{'0' * 32}"

        expect(response).to have_http_status(:not_found)
      end

      it "answers 404 for an id with the wrong shape" do
        get "/social/photos/not-an-id"

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
