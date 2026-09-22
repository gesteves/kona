require "rails_helper"
require "vips"

RSpec.describe PhotoBlob do
  # ⚠️ Each example gives a PATH, because the code reads the temporary file of Puma and never a
  # String of the bytes. Refer to the ⚠️ at the top of that file.
  after { @files&.each(&:close!) }

  # A picture of one colour, as the bytes of a file.
  def picture(width, height, format: ".png", bands: 3)
    image = Vips::Image.black(width, height, bands: bands).copy(interpretation: :srgb) + [ 200, 30, 30, 255 ].first(bands)
    image.cast(:uchar).write_to_buffer(format)
  end

  # The same picture, written to a file, as its path.
  def picture_file(width, height, format: ".png", bands: 3)
    write_file(picture(width, height, format: format, bands: bands), format: format)
  end

  # @return [String] The path of a temporary file that holds these bytes.
  def write_file(bytes, format: ".png")
    file = Tempfile.new([ "photo", format ])
    file.binmode
    file.write(bytes)
    file.flush
    (@files ||= []) << file
    file.path
  end

  it "gives a JPEG below the limit, with its size in pixels" do
    photo = described_class.prepare(picture_file(300, 200))

    expect(photo[:bytes].b[0, 2]).to eq("\xFF\xD8".b)
    expect(photo[:bytes].bytesize).to be <= described_class::LIMIT
    expect(photo[:width]).to eq(300)
    expect(photo[:height]).to eq(200)
  end

  it "fits a large picture inside the longest edge" do
    photo = described_class.prepare(picture_file(6000, 2000))

    expect(photo[:width]).to eq(described_class::MAX_EDGE)
    expect(photo[:height]).to eq(1333)
  end

  it "keeps a picture inside the longest edge at its own size" do
    photo = described_class.prepare(picture_file(3000, 1000))

    expect(photo[:width]).to eq(3000)
    expect(photo[:height]).to eq(1000)
  end

  # A JPEG has no alpha channel: without the flatten, a transparent PNG gets a black background.
  it "flattens a picture with an alpha channel" do
    photo = described_class.prepare(picture_file(40, 40, bands: 4))
    decoded = Vips::Image.new_from_buffer(photo[:bytes], "")

    expect(decoded.bands).to eq(3)
    expect(decoded.has_alpha?).to be(false)
  end

  it "refuses a file that is not a picture, and one that holds nothing" do
    expect { described_class.prepare(write_file("not a picture at all")) }
      .to raise_error(described_class::NotAnImageError)
    expect { described_class.prepare(write_file("")) }.to raise_error(described_class::NotAnImageError)
    expect { described_class.prepare("") }.to raise_error(described_class::NotAnImageError)
    expect { described_class.prepare("/no/such/photo.jpg") }.to raise_error(described_class::NotAnImageError)
  end

  it "refuses a picture that stays above the limit after the last step" do
    stub_const("PhotoBlob::LIMIT", 10)

    expect { described_class.prepare(picture_file(300, 200)) }.to raise_error(described_class::WontFitError)
  end

  describe ".thumbnail" do
    it "fits the picture in the edge and gives a JPEG" do
      thumbnail = described_class.thumbnail(picture_file(4000, 2000))

      expect(thumbnail[:width]).to eq(described_class::THUMBNAIL_EDGE)
      expect(thumbnail[:height]).to eq(described_class::THUMBNAIL_EDGE / 2)
      expect(Vips::Image.new_from_buffer(thumbnail[:bytes], "").get("vips-loader")).to eq("jpegload_buffer")
    end

    # ⚠️ `size: :down` — a small picture stays small and the code does not make it larger.
    it "does not make a picture larger" do
      thumbnail = described_class.thumbnail(picture_file(40, 20))

      expect(thumbnail[:width]).to eq(40)
      expect(thumbnail[:height]).to eq(20)
    end

    it "flattens an alpha channel, because a JPEG has none" do
      thumbnail = described_class.thumbnail(picture_file(60, 40, bands: 4))
      decoded = Vips::Image.new_from_buffer(thumbnail[:bytes], "")

      expect(decoded.bands).to eq(3)
      expect(decoded.has_alpha?).to be(false)
    end

    # ⚠️ The decode IS the check that the file is a picture, and the media uploader runs it before
    # it sends one byte to Contentful.
    it "refuses a file that is not a picture, and one that holds nothing" do
      expect { described_class.thumbnail(write_file("not a picture at all")) }
        .to raise_error(described_class::NotAnImageError)
      expect { described_class.thumbnail(write_file("")) }.to raise_error(described_class::NotAnImageError)
      expect { described_class.thumbnail("") }.to raise_error(described_class::NotAnImageError)
      expect { described_class.thumbnail("/no/such/photo.jpg") }.to raise_error(described_class::NotAnImageError)
    end
  end
end
