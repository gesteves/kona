module Admin
  # One file of the media uploader, between the pick and the submit. The page uploads each file
  # here at the moment the owner picks it, and the form then carries the id and the words.
  #
  # ⚠️ One file for each request, on purpose. A tile on the page is one upload, thus a 422 names
  # one file.
  #
  # ⚠️ **The ORIGINAL bytes go to Contentful here**, in the request, and not in the job. `app` and
  # `worker` are different fly machines, thus the job cannot read the temporary file of this
  # request, and the other way — Redis — would hold as much as 500MB of camera JPEG. The transfer
  # happens while the owner writes the alt text, thus it costs no waiting.
  class ContentfulUploadFilesController < BaseController
    # The most bytes of one upload. A camera JPEG is 20MB to 38MB, thus a smaller limit refuses the
    # true photos of the owner.
    #
    # ⚠️ **Cloudflare Pro refuses a request body above 100MB**, at the edge, with a 413 that this
    # app never sees and cannot write a message for. Thus this limit must stay well below that
    # number.
    # ⚠️ The file stays on the DISK: `PhotoBlob` and `ContentfulManagement#create_upload` both read
    # the temporary file of Puma, thus the size of the picture does not decide how much memory the
    # request uses. `RequestBodyLimit` refuses a larger body before this code runs.
    MAX_BYTES = 50.megabytes

    # POST /contentful/uploads/files
    #
    # Answers `{ id, path, alt_path, title, width, height }`, or a 4xx with `{ error }`.
    def create
      return refuse(t("admin.contentful_uploads.files.unconfigured"), status: :service_unavailable) unless ContentfulManagement.configured?

      file = params[:file]
      return refuse(t("admin.contentful_uploads.files.no_file")) unless file.is_a?(ActionDispatch::Http::UploadedFile)

      if file.size > MAX_BYTES
        return refuse(t("admin.contentful_uploads.files.too_large",
                        size: ActiveSupport::NumberHelper.number_to_human_size(file.size),
                        limit: ActiveSupport::NumberHelper.number_to_human_size(MAX_BYTES)))
      end

      # ⚠️ The decode is the check that the file IS a picture, and it runs BEFORE the app sends one
      # byte to Contentful. A content type from the browser is not such a check.
      # ⚠️ It gives the PATH and not `file.read`. Refer to the ⚠️ on MAX_BYTES above.
      thumbnail = PhotoBlob.thumbnail(file.tempfile.path)

      upload_id = ContentfulManagement.new.create_upload(file.tempfile.path)
      return refuse(t("admin.contentful_uploads.files.upload_refused"), status: :bad_gateway) if upload_id.blank?

      file_name = File.basename(file.original_filename.to_s)
      id = StagedUpload.new.store(
        thumbnail: thumbnail[:bytes], upload_id: upload_id, file_name: file_name,
        content_type: file.content_type.to_s, width: thumbnail[:width], height: thumbnail[:height]
      )

      render json: { id: id, path: contentful_upload_file_path(id),
                     alt_path: contentful_upload_file_alt_path(id),
                     title: File.basename(file_name, ".*"),
                     width: thumbnail[:width], height: thumbnail[:height] }
    rescue PhotoBlob::NotAnImageError
      refuse(t("admin.contentful_uploads.files.not_an_image"))
    rescue StandardError => e
      # ⚠️ A 502 with a sentence, and not a 500 with none: the upload of the bytes is one outbound
      # call in this request, and the page must be able to say what failed. The report keeps it
      # from being silent.
      ErrorReporter.report_upstream(e, service: "ContentfulManagement", context: "media upload")
      refuse(t("admin.contentful_uploads.files.upload_refused"), status: :bad_gateway)
    end

    # GET /contentful/uploads/files/:id
    #
    # The thumbnail of a tile. ⚠️ It is NOT the picture that Contentful holds: that one is the
    # original file. `OwnerFacing` gives `no-store`.
    def show
      staged = StagedUpload.new.fetch(params[:id].to_s)
      return head :not_found if staged.nil?

      send_data staged[:thumbnail], type: "image/jpeg", disposition: "inline"
    end

    # POST /contentful/uploads/files/:id/alt
    #
    # Writes the alt text of one file with Claude, and answers `{ alt }`. ⚠️ It sends the
    # THUMBNAIL, and not the original: a 38MB camera JPEG as base64 is far past what the call
    # should carry, and the description does not change with the resolution.
    def alt
      staged = StagedUpload.new.fetch(params[:id].to_s)
      return head :not_found if staged.nil?
      return refuse(t("admin.contentful_uploads.files.alt_not_configured"), status: :service_unavailable) unless AltText.configured?

      text = AltText.generate(image: staged[:thumbnail])
      return refuse(t("admin.contentful_uploads.files.alt_failed"), status: :bad_gateway) if text.blank?

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
