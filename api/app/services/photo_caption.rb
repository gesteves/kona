# Reads the caption that a photo app wrote into an image file, for the alt text of an upload.
#
# The media uploader and the Social media page write this caption into an empty alt text field.
# Claude then writes the alt text only for a file with no caption.
#
# ⚠️ **Read the caption in the upload request, from the ORIGINAL file.** `PhotoBlob` removes each
# metadata field with `strip: true`, thus the stored JPEG and the thumbnail have no caption.
# ⚠️ It reads the header from the DISK, and it decodes no pixel. Refer to the ⚠️ in `PhotoBlob`.
#
# It fails soft: it returns nil for each problem. A caption is never a reason to refuse an upload.
module PhotoCaption
  # The XMP field of the caption. Lightroom, Photos, and Capture One write it.
  XMP_NAMESPACES = {
    "dc" => "http://purl.org/dc/elements/1.1/",
    "rdf" => "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  }.freeze

  # The EXIF field of the caption.
  EXIF_FIELD = "exif-ifd0-ImageDescription".freeze

  # ⚠️ libvips gives an EXIF text as `"value (value, ASCII, N components, N bytes)"`. The
  # backreference finds the true end of the value, because a caption can contain " (".
  EXIF_FORMAT = /\A(.*) \(\1, ASCII, \d+ components?, \d+ bytes?\)\z/m

  # The texts that a camera writes into ImageDescription with no person. They are not a caption.
  CAMERA_DEFAULTS = [
    /\A(?:[\w-]+ )*digital camera\z/i,
    /\A(?:sony|samsung|nikon|canon|pentax|fujifilm|olympus) dsc\z/i,
    /\Adefault\z/i,
    /\Ascreenshot\z/i
  ].freeze

  module_function

  # @param path [String] The upload, on the disk.
  # @return [String, nil] The caption, or nil when the file has none or libvips cannot read it.
  def read(path)
    return if path.blank? || !File.exist?(path)

    # ⚠️ The require is here for the reason in PhotoBlob.prepare.
    require "vips"

    image = Vips::Image.new_from_file(path)
    [ xmp_caption(image), exif_caption(image) ].find(&:present?)
  rescue StandardError, LoadError
    nil
  end

  # @param image [Vips::Image]
  # @return [String, nil] `dc:description` of the XMP block, in the default language.
  def xmp_caption(image)
    return unless image.get_typeof("xmp-data").positive?

    xml = Nokogiri::XML(image.get("xmp-data").dup.force_encoding(Encoding::UTF_8).scrub(""))
    items = xml.xpath("//dc:description//rdf:li", XMP_NAMESPACES)
    item = items.find { |li| li["xml:lang"] == "x-default" } || items.first
    clean(item&.text)
  end

  # @param image [Vips::Image]
  # @return [String, nil] The EXIF ImageDescription, when it is not a camera default.
  def exif_caption(image)
    return unless image.get_typeof(EXIF_FIELD).positive?

    raw = image.get(EXIF_FIELD).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
    text = clean(raw[EXIF_FORMAT, 1] || raw)
    text unless text.nil? || CAMERA_DEFAULTS.any? { |pattern| pattern.match?(text) }
  end

  # @param text [String, nil]
  # @return [String, nil] The text on one line with single spaces, or nil when it is blank.
  def clean(text)
    text.to_s.gsub(/[[:cntrl:][:space:]]+/, " ").strip.presence
  end
end
