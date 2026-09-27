require "rails_helper"

# Meta GETs each photo of a Threads post from this public route. The signature is the permission.
RSpec.describe "Api::SocialPhotos", type: :request do
  let(:store) { SocialPhotos.new }
  let(:jpeg) { "\xFF\xD8\xFF\xE0jpeg".b }
  let!(:id) { store.store(image: jpeg, width: 4, height: 3) }

  def path(id, signature = SocialPhotos.signature(id))
    "/api/social-photos/#{id}/#{signature}"
  end

  it "gives the JPEG for a correct signature, with no token and no cache" do
    get path(id)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/jpeg")
    expect(response.body.b).to eq(jpeg)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "gives a 404 for a wrong signature" do
    get path(id, "0" * 64)

    expect(response).to have_http_status(:not_found)
  end

  it "gives a 404 for the signature of another photo" do
    other = store.store(image: jpeg, width: 4, height: 3)

    get path(id, SocialPhotos.signature(other))

    expect(response).to have_http_status(:not_found)
  end

  it "gives a 404 for a photo that is gone" do
    store.discard([ id ])

    get path(id)

    expect(response).to have_http_status(:not_found)
  end
end
