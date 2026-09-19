module Admin
  # The photos of a draft on the Social media page. The composer uploads each photo here at the
  # moment the owner picks it, and the form then carries the id of the photo and its alt text.
  #
  # ⚠️ One file for each request, on purpose. A tile on the page is one upload, and a 422 then
  # names one file. The bytes go into Redis, because `app` and `worker` are different fly
  # machines and the job cannot read a temporary file of this request.
  class SocialPhotosController < BaseController
    # The most bytes of one upload. A camera JPEG is 20MB to 38MB, thus a smaller limit refuses the
    # true photos of the owner.
    #
    # ⚠️ **Cloudflare Pro refuses a request body above 100MB**, at the edge, with a 413 that this
    # app never sees and cannot write a message for. Thus this limit must stay well below that
    # number, or a large upload fails with no words of ours.
    # ⚠️ The file stays on the DISK: `PhotoBlob` reads the temporary file of Puma, thus neither
    # this limit nor the size of the picture decides how much memory the request uses.
    # `RequestBodyLimit` refuses a larger body before this code runs.
    MAX_BYTES = 50.megabytes

    # POST /social/photos
    #
    # Answers `{ id, path, width, height }`, or a 422 with `{ error }`.
    def create
      file = params[:photo]
      return refuse(t("admin.social.photos.no_file")) unless file.is_a?(ActionDispatch::Http::UploadedFile)

      if file.size > MAX_BYTES
        return refuse(t("admin.social.photos.too_large",
                        size: ActiveSupport::NumberHelper.number_to_human_size(file.size),
                        limit: ActiveSupport::NumberHelper.number_to_human_size(MAX_BYTES)))
      end

      # ⚠️ It gives the PATH and not `file.read`. Refer to the ⚠️ on MAX_BYTES above.
      photo = PhotoBlob.prepare(file.tempfile.path)
      id = SocialPhotos.new.store(image: photo[:bytes], width: photo[:width], height: photo[:height])

      render json: { id: id, path: social_photo_path(id), alt_path: social_photo_alt_path(id),
                     width: photo[:width], height: photo[:height] }
    rescue PhotoBlob::NotAnImageError
      refuse(t("admin.social.photos.not_an_image"))
    rescue PhotoBlob::WontFitError
      refuse(t("admin.social.photos.wont_fit"))
    end

    # GET /social/photos/:id
    #
    # The stored JPEG, for the thumbnail of a tile. ⚠️ It is the same bytes that go up as the blob.
    # `OwnerFacing` gives `no-store`.
    def show
      photo = SocialPhotos.new.fetch(params[:id].to_s)
      return head :not_found if photo.nil?

      send_data photo[:image], type: "image/jpeg", disposition: "inline"
    end

    # POST /social/photos/:id/alt
    #
    # Writes the alt text of one photo with Claude, and answers `{ alt }`. ⚠️ It sends the stored
    # JPEG, which is the picture that Bluesky will show. A 503 says that there is no API key, and
    # a 502 says that Claude gave no answer; the page shows each one in a toast.
    def alt
      photo = SocialPhotos.new.fetch(params[:id].to_s)
      return head :not_found if photo.nil?
      return refuse(t("admin.social.photos.alt_not_configured"), status: :service_unavailable) unless AltText.configured?

      text = AltText.generate(image: photo[:image])
      return refuse(t("admin.social.photos.alt_failed"), status: :bad_gateway) if text.blank?

      render json: { alt: text }
    end

    private

    # @param message [String]
    # @param status [Symbol]
    def refuse(message, status: :unprocessable_content)
      render json: { error: message }, status: status
    end
  end
end
