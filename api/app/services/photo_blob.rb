# Makes a photo that the owner uploads into the JPEG that goes to Bluesky as a blob.
#
# It fits the picture in a square of MAX_EDGE, and it makes the quality and the size lower until
# the file is below the blob limit of Bluesky.
#
# ⚠️ The decode IS the check that the bytes are a picture. A content type from the browser is not
# one: a person can name any file with any extension.
# ⚠️ `strip: true` removes each EXIF field, and that includes the GPS position of a personal photo.
module PhotoBlob
  class Error < StandardError; end
  # The bytes are not a picture that libvips can read.
  class NotAnImageError < Error; end
  # No step gave a file below the limit.
  class WontFitError < Error; end

  # The longest side of the result, in pixels, before the size goes down. It is the resolution
  # limit of the client of Bluesky.
  MAX_EDGE = 4000

  # The most bytes of the result.
  LIMIT = Bluesky::MAX_IMAGE_BYTES

  # The steps, in order. The quality goes down first, because a person sees a smaller picture before
  # they see a lower quality. ⚠️ A full-size photo at Q85 is nearly always above LIMIT, thus the
  # first steps are the usual path and not a special case.
  STEPS = [
    { edge: 4000, quality: 85 },
    { edge: 4000, quality: 75 },
    { edge: 4000, quality: 65 },
    { edge: 3000, quality: 65 },
    { edge: 2000, quality: 65 },
    { edge: 1600, quality: 60 },
    { edge: 1200, quality: 55 }
  ].freeze

  # @param bytes [String] The upload.
  # @return [Hash] `{ bytes:, width:, height: }`, a JPEG below LIMIT and its size in pixels.
  # @raise [NotAnImageError] When libvips cannot read the bytes.
  # @raise [WontFitError] When no step gives a file below LIMIT.
  def self.prepare(bytes)
    raise NotAnImageError, "The upload is empty" if bytes.blank?

    # ⚠️ The require is here and not at the top of the file, as in AtProto#shrink_image. libvips
    # is a native library, and a require at the top would make each boot need it.
    # ⚠️ LoadError is not a StandardError, thus the rescue below names it.
    require "vips"

    smallest = nil
    STEPS.each do |step|
      # ⚠️ `thumbnail_buffer` shrinks at the decode and applies the EXIF orientation. A full decode
      # of a camera file is more than 100MB of pixels on a 512MB machine.
      image = Vips::Image.thumbnail_buffer(bytes, step[:edge], height: step[:edge], size: :down)
      # A JPEG has no alpha channel: without this, a transparent PNG gets a black background.
      image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
      image = image.colourspace(:srgb) unless image.interpretation == :srgb

      smallest = { bytes: image.jpegsave_buffer(Q: step[:quality], strip: true),
                   width: image.width, height: image.height }
      return smallest if smallest[:bytes].bytesize <= LIMIT
    end

    raise WontFitError, "The photo is #{smallest[:bytes].bytesize} bytes after the last step"
  rescue Vips::Error, LoadError => e
    raise NotAnImageError, e.message
  end
end
