# The parts that the two picture upload endpoints of the admin share: the size limit, the JSON
# refusal, and the alt text that Claude writes. Admin::SocialPhotosController and
# Admin::ContentfulUploadFilesController each take one file for each request and answer JSON to a
# tile of their page.
#
# Each method takes the i18n scope of its controller, because the two pages have different words.
module PictureUpload
  # The most bytes of one upload. A camera JPEG is 20MB to 38MB, thus a smaller limit refuses the
  # true photos of the owner.
  #
  # ⚠️ **Cloudflare Pro refuses a request body above 100MB**, at the edge, with a 413 that this
  # app never sees and cannot write a message for. Thus this limit must stay well below that
  # number, or a large upload fails with no words of ours.
  # ⚠️ The file stays on the DISK: each reader takes the path of the temporary file of Puma, thus
  # neither this limit nor the size of the picture decides how much memory the request uses.
  # `RequestBodyLimit` refuses a larger body before this code runs.
  MAX_BYTES = 50.megabytes

  private

  # @param file [ActionDispatch::Http::UploadedFile]
  # @param scope [String] The i18n scope that holds `too_large`.
  # @return [String, nil] The message for a file past MAX_BYTES, or nil for a file that fits.
  def too_large_message(file, scope:)
    return if file.size <= MAX_BYTES

    t("#{scope}.too_large", size: ActiveSupport::NumberHelper.number_to_human_size(file.size),
                            limit: ActiveSupport::NumberHelper.number_to_human_size(MAX_BYTES))
  end

  # Writes the alt text of one picture with Claude, and answers `{ alt }`. A 503 says that there is
  # no API key, and a 502 says that Claude gave no answer. The page shows each one in a toast.
  # @param image [String] The JPEG bytes that Claude reads.
  # @param scope [String] The i18n scope that holds `alt_not_configured` and `alt_failed`.
  def render_alt_text(image, scope:)
    return refuse(t("#{scope}.alt_not_configured"), status: :service_unavailable) unless AltText.configured?

    text = AltText.generate(image: image)
    return refuse(t("#{scope}.alt_failed"), status: :bad_gateway) if text.blank?

    render json: { alt: text }
  end

  # @param message [String]
  # @param status [Symbol]
  def refuse(message, status: :unprocessable_content)
    render json: { error: message }, status: status
  end
end
