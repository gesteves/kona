require "rails_helper"

RSpec.describe ContentfulUploadPresenter do
  def present(overrides = {})
    described_class.new({
      "id" => "a" * 32, "title" => "IMG_4821", "file_name" => "IMG_4821.jpg",
      "status" => "processing", "asset_id" => nil, "error" => nil,
      "uploaded_at" => "2026-09-22T12:00:00Z"
    }.merge(overrides))
  end

  it "reads the record" do
    upload = present("asset_id" => "asset-1")

    expect(upload.id).to eq("a" * 32)
    expect(upload.title).to eq("IMG_4821")
    expect(upload.file_name).to eq("IMG_4821.jpg")
    expect(upload.asset_id).to eq("asset-1")
    expect(upload.uploaded_at).to eq("2026-09-22T12:00:00Z")
  end

  it "answers each state, one at a time" do
    expect(present).to be_processing
    expect(present("status" => "published")).to be_published
    expect(present("status" => "failed")).to be_failed
  end

  # A record from a version before a new status, or one that a person edited, must still render.
  it "reads a status that it does not know as processing" do
    expect(present("status" => "sideways").status).to eq("processing")
    expect(present("status" => nil).status).to eq("processing")
  end

  it "takes the label from the locale file, and keeps the variant in the code" do
    expect(present.status_label).to eq(I18n.t("admin.contentful_uploads.status.processing"))
    expect(present("status" => "published").status_variant).to eq("success")
    expect(present("status" => "failed").status_variant).to eq("danger")
  end

  it "gives nil for an error and an asset id that are blank" do
    expect(present("error" => "", "asset_id" => "").error).to be_nil
    expect(present("error" => "", "asset_id" => "").asset_id).to be_nil
  end

  describe described_class::File do
    # ⚠️ Each member has a blank default, because the partial writes each one into an attribute of
    # a form control.
    it "defaults each member to an empty string" do
      file = described_class.new

      expect(file.id).to eq("")
      expect(file.title).to eq("")
      expect(file.alt).to eq("")
    end

    it "keeps the values that it gets, as strings" do
      file = described_class.new(id: "b" * 32, title: :name, alt: "Words")

      expect(file.id).to eq("b" * 32)
      expect(file.title).to eq("name")
      expect(file.alt).to eq("Words")
    end
  end
end
