require "rails_helper"

RSpec.describe MapTrackPresenter do
  def present(overrides = {})
    described_class.new(
      record: {
        "id" => "morning_run_abc",
        "title" => "2026 Morning Run",
        "activity_type" => "Running",
        "status" => "ready",
        "uploaded_at" => "2026-07-25T13:32:14Z",
        "settings" => { "padding_top" => 80 }
      }.merge(overrides),
      show_path: "/course-maps/morning_run_abc",
      preview_path: "/course-maps/morning_run_abc/preview",
      download_path: "/course-maps/morning_run_abc/download",
      delete_path: "/course-maps/morning_run_abc"
    )
  end

  describe "status" do
    it "labels and colors each state" do
      expect(present).to have_attributes(status_label: I18n.t("admin.course_maps.status.ready"), status_variant: "success", ready?: true)
      expect(present("status" => "processing"))
        .to have_attributes(status_label: I18n.t("admin.course_maps.status.processing"), status_variant: "neutral", processing?: true)
      expect(present("status" => "failed"))
        .to have_attributes(status_label: I18n.t("admin.course_maps.status.failed"), status_variant: "danger", failed?: true)
    end

    # A record from an older version, and a record with an incorrect shape, must still render a
    # card.
    it "treats an unrecognized status as still processing" do
      expect(present("status" => "banana")).to have_attributes(status: "processing")
    end
  end

  describe "#summary" do
    it "is the sport" do
      expect(present.summary).to eq("Running")
    end
  end

  describe "#settings" do
    it "keeps what's stored" do
      expect(present.setting("padding_top")).to eq(80)
    end

    # ⚠️ A record from before a setting existed must still render, thus each key gets a value.
    it "fills in a setting the stored record predates" do
      expect(present.setting("track_color")).to eq("#bf0222")
      expect(present.setting("style_preset")).to eq("mapbox://styles/mapbox/outdoors-v12")
    end
  end

  describe "the map style" do
    # A record from before the dropdown existed kept each style in style_url. That would now show a
    # Mapbox default in the "custom style" box.
    it "moves a Mapbox default out of the custom box and into the dropdown" do
      track = present("settings" => { "style_url" => "mapbox://styles/mapbox/dark-v11" })

      expect(track.setting("style_preset")).to eq("mapbox://styles/mapbox/dark-v11")
      expect(track.setting("style_url")).to eq("")
    end

    it "leaves a genuinely custom style where it is" do
      track = present("settings" => { "style_url" => "mapbox://styles/gesteves/winter" })

      expect(track.setting("style_url")).to eq("mapbox://styles/gesteves/winter")
    end
  end

  it "names a delete dialog uniquely per track" do
    expect(present.dialog_id).to eq("map-delete-morning_run_abc")
  end
end
