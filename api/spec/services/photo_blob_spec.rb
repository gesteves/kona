require "rails_helper"
require "vips"

RSpec.describe PhotoBlob do
  # A picture of one colour, as the bytes of a file.
  def picture(width, height, format: ".png", bands: 3)
    image = Vips::Image.black(width, height, bands: bands).copy(interpretation: :srgb) + [ 200, 30, 30, 255 ].first(bands)
    image.cast(:uchar).write_to_buffer(format)
  end

  it "gives a JPEG below the limit, with its size in pixels" do
    photo = described_class.prepare(picture(300, 200))

    expect(photo[:bytes].b[0, 2]).to eq("\xFF\xD8".b)
    expect(photo[:bytes].bytesize).to be <= described_class::LIMIT
    expect(photo[:width]).to eq(300)
    expect(photo[:height]).to eq(200)
  end

  it "fits a large picture inside the longest edge" do
    photo = described_class.prepare(picture(6000, 2000))

    expect(photo[:width]).to eq(described_class::MAX_EDGE)
    expect(photo[:height]).to eq(1333)
  end

  it "keeps a picture inside the longest edge at its own size" do
    photo = described_class.prepare(picture(3000, 1000))

    expect(photo[:width]).to eq(3000)
    expect(photo[:height]).to eq(1000)
  end

  # A JPEG has no alpha channel: without the flatten, a transparent PNG gets a black background.
  it "flattens a picture with an alpha channel" do
    photo = described_class.prepare(picture(40, 40, bands: 4))
    decoded = Vips::Image.new_from_buffer(photo[:bytes], "")

    expect(decoded.bands).to eq(3)
    expect(decoded.has_alpha?).to be(false)
  end

  it "refuses bytes that are not a picture" do
    expect { described_class.prepare("not a picture at all") }.to raise_error(described_class::NotAnImageError)
    expect { described_class.prepare("") }.to raise_error(described_class::NotAnImageError)
  end

  it "refuses a picture that stays above the limit after the last step" do
    stub_const("PhotoBlob::LIMIT", 10)

    expect { described_class.prepare(picture(300, 200)) }.to raise_error(described_class::WontFitError)
  end
end
