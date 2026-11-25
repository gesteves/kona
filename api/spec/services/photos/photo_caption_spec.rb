require "rails_helper"
require "vips"

RSpec.describe PhotoCaption do
  # A small JPEG on the disk, with the metadata that the example gives.
  # @param exif [String, nil] The EXIF ImageDescription.
  # @param xmp [String, nil] The XMP dc:description, in the default language.
  def jpeg(exif: nil, xmp: nil)
    image = (Vips::Image.black(20, 10, bands: 3).copy(interpretation: :srgb) + [ 10, 120, 200 ]).cast(:uchar)
    image = image.mutate do |m|
      m.set_type!(GObject::GSTR_TYPE, PhotoCaption::EXIF_FIELD, exif) if exif
      m.set_type!(Vips::BLOB_TYPE, "xmp-data", xmp_packet(xmp)) if xmp
    end

    file = Tempfile.new([ "caption", ".jpg" ])
    image.jpegsave(file.path)
    file
  end

  def xmp_packet(text)
    <<~XML
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:description><rdf:Alt><rdf:li xml:lang="x-default">#{text}</rdf:li></rdf:Alt></dc:description>
          </rdf:Description>
        </rdf:RDF>
      </x:xmpmeta>
    XML
  end

  describe ".read" do
    it "reads the XMP caption, with its accents" do
      expect(described_class.read(jpeg(xmp: "Swimmers at the start, día uno").path))
        .to eq("Swimmers at the start, día uno")
    end

    it "reads the EXIF caption, with no libvips suffix" do
      expect(described_class.read(jpeg(exif: "A runner (bib 42) at the finish").path))
        .to eq("A runner (bib 42) at the finish")
    end

    # ⚠️ XMP is UTF-8, and libexif writes EXIF text as ASCII.
    it "prefers the XMP caption to the EXIF one" do
      expect(described_class.read(jpeg(exif: "Old words", xmp: "New words").path)).to eq("New words")
    end

    it "puts the caption on one line" do
      expect(described_class.read(jpeg(xmp: "  Two\n  lines  ").path)).to eq("Two lines")
    end

    it "ignores a text that a camera writes" do
      [ "OLYMPUS DIGITAL CAMERA", "SONY DSC", "KONICA MINOLTA DIGITAL CAMERA" ].each do |text|
        expect(described_class.read(jpeg(exif: text).path)).to be_nil
      end
    end

    it "uses the EXIF caption when the XMP one is blank" do
      expect(described_class.read(jpeg(exif: "The bike rack", xmp: "  ").path)).to eq("The bike rack")
    end

    it "gives nil for a file with no caption" do
      expect(described_class.read(jpeg.path)).to be_nil
    end

    it "gives nil for a file that is not a picture, and does not raise" do
      file = Tempfile.new([ "words", ".jpg" ])
      file.write("these are words")
      file.flush

      expect(described_class.read(file.path)).to be_nil
    end

    it "gives nil for a path that does not exist" do
      expect(described_class.read("/nonexistent/photo.jpg")).to be_nil
      expect(described_class.read(nil)).to be_nil
    end
  end
end
