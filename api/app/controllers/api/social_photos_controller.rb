module Api
  # Gives one staged photo of the Social media page to Meta, which GETs each image of a Threads post
  # from its URL. Refer to SocialPhotos.public_url.
  class SocialPhotosController < BaseController
    # This is public, on purpose: Meta sends no token. The signature in the path is the permission.
    skip_before_action :authenticate_bearer_token!

    # GET /api/social-photos/:id/:signature
    #
    # A bad signature and a missing photo both give a 404, thus the answer tells nothing about an id.
    def show
      id = params[:id].to_s
      return head :not_found unless SocialPhotos.valid_signature?(id, params[:signature].to_s)

      photo = SocialPhotos.new.fetch(id)
      return head :not_found if photo.nil?

      response.cache_control.replace(no_store: true)
      send_data photo[:image], type: "image/jpeg", disposition: "inline"
    end
  end
end
