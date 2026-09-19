module Admin
  # The photos of a draft on the Social media page. The composer uploads each photo here at the
  # moment the owner picks it, and the form then carries the id of the photo and its alt text.
  #
  # ⚠️ One file for each request, on purpose. A tile on the page is one upload, and a 422 then
  # names one file. The bytes go into Redis, because `app` and `worker` are different fly
  # machines and the job cannot read a temporary file of this request.
  class SocialPhotosController < BaseController
    # The most bytes of one upload. ⚠️ The request reads that much into memory, on a 512MB machine
    # with three Puma threads. RequestBodyLimit refuses a larger body before this code runs, and
    # `PhotoBlob` shrinks at the decode, thus the pixels never take more than the file.
    MAX_BYTES = 25.megabytes

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

      photo = PhotoBlob.prepare(file.read)
      id = SocialPhotos.new.store(image: photo[:bytes], width: photo[:width], height: photo[:height])

      render json: { id: id, path: social_photo_path(id), width: photo[:width], height: photo[:height] }
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

    private

    # @param message [String]
    def refuse(message)
      render json: { error: message }, status: :unprocessable_content
    end
  end
end
