require "rails_helper"

# config/srcsets.yml is a copy of web/data/srcsets.yml. The api renders the trending card and the
# build renders each other card, and the two go on the same page. Thus a difference gives one image
# at the wrong size, or a `sizes` that describes the wrong element, in the middle of one section.
# Nothing else compares the two, and neither app reads the file of the other one: the Docker image
# of this app holds `api/` only.
RSpec.describe "web ↔ api srcsets contract" do
  api_path = Rails.root.join("config/srcsets.yml")
  web_path = Rails.root.join("../web/data/srcsets.yml")

  it "keeps config/srcsets.yml the same as web/data/srcsets.yml, word for word" do
    expect(File.read(api_path)).to eq(File.read(web_path)),
      "config/srcsets.yml and web/data/srcsets.yml are different. " \
      "Run `cp web/data/srcsets.yml api/config/srcsets.yml` from the root of the repo."
  end

  # ⚠️ This is the reason for the copy. The two checks above and below are not the same: the file
  # can be equal and the helper can still read the wrong key.
  it "renders the card from the `card` variant of that file" do
    card = YAML.load_file(web_path).fetch("card")

    expect(ImagesHelper::CARD_SIZES).to eq(card.fetch("sizes").join(", "))
    expect(ImagesHelper::CARD_WIDTHS).to eq(card.fetch("widths"))
  end

  # ⚠️ The shape of a card is in this file ONLY. Both apps read it for the `h` of each candidate,
  # and both write it into the markup as --card-ratio, which _entry.scss and _skeleton.scss read.
  # A number in a stylesheet or in a helper would be a second place to edit, and nothing would
  # compare the two.
  it "takes the card shape from that file, and holds it nowhere else" do
    ratio = YAML.load_file(web_path).fetch("card").fetch("ratio")
    w, h = ratio.split(":", 2).map(&:to_i)

    expect(ratio).to match(/\A\d+:\d+\z/), "the card ratio uses the width:height syntax"
    expect(ImagesHelper::CARD_RATIO).to eq(Rational(h, w))
    expect(ImagesHelper::CARD_ASPECT_RATIO).to eq("#{w} / #{h}")
  end

  # `cover_image_tag` reads widths.first for the `src`. With the list in another order, the src
  # would be a candidate for a phone, and each desktop card would then be soft.
  it "keeps the 1x desktop width first in the card widths" do
    expect(ImagesHelper::CARD_WIDTHS.first).to eq(592)
    expect(ImagesHelper::CARD_SIZES).to include("(min-width: 1280px) 592px")
  end
end
