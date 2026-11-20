module Admin
  # The photos of a draft on the Social media page. The composer uploads each photo here at the
  # moment the owner picks it, and the form then carries the id of the photo and its alt text.
  #
  # ⚠️ One file for each request, on purpose. A tile on the page is one upload, and a 422 then
  # names one file. The bytes go into Redis, because `app` and `worker` are different fly
  # machines and the job cannot read a temporary file of this request.
  class SocialPhotosController < BaseController
    include PictureUpload

    I18N_SCOPE = "admin.social.photos".freeze

    # POST /social/photos
    #
    # Answers `{ id, path, alt_path, caption, width, height }`, or a 422 with `{ error }`.
    # `caption` is the caption in the metadata of the file, or nil. The page writes it into the
    # alt text field, and Claude then writes no alt text.
    def create
      file = params[:photo]
      return refuse(t("admin.social.photos.no_file")) unless file.is_a?(ActionDispatch::Http::UploadedFile)

      too_large = too_large_message(file, scope: I18N_SCOPE)
      return refuse(too_large) if too_large

      # ⚠️ It gives the PATH and not `file.read`. Refer to the ⚠️ on PictureUpload::MAX_BYTES.
      photo = PhotoBlob.prepare(file.tempfile.path)
      # ⚠️ It reads the ORIGINAL file: the stored JPEG has no metadata.
      caption = PhotoCaption.read(file.tempfile.path)
      id = SocialPhotos.new.store(image: photo[:bytes], width: photo[:width], height: photo[:height])

      render json: { id: id, path: social_photo_path(id), alt_path: social_photo_alt_path(id),
                     caption: caption, width: photo[:width], height: photo[:height] }
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
    # JPEG, which is the picture that Bluesky will show.
    def alt
      photo = SocialPhotos.new.fetch(params[:id].to_s)
      return head :not_found if photo.nil?

      render_alt_text(photo[:image], scope: I18N_SCOPE)
    end
  end
end
