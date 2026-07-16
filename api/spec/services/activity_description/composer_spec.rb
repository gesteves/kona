require "rails_helper"

RSpec.describe ActivityDescription::Composer do
  describe ".headline" do
    it "preserves multi-paragraph user prose verbatim" do
      description = "Felt great today.\n\nNegative split the second half."
      expect(described_class.headline(description)).to eq(description)
    end

    it "strips our stat lines and any LLM-picked weather emoji line" do
      description = <<~TEXT.strip
        Big day out.

        🗓️ 2 hours of sweet spot
        🌤️ Mild and sunny with a light breeze
        ⚡️ Avg 200 W · NP 210 W
        🌡️ Max HSI 2.5 · Median HSI 1.7
        🔥 12.4 Whoop Strain
      TEXT
      expect(described_class.headline(description)).to eq("Big day out.")
    end

    it "collapses runs of blank lines left by stripped blocks" do
      description = "Line one.\n\n\n\n🔥 12.4 Whoop Strain\n\n\nLine two."
      expect(described_class.headline(description)).to eq("Line one.\n\nLine two.")
    end

    it "returns nil when only stat lines remain" do
      expect(described_class.headline("⚡️ Avg 200 W\n🔥 12.4 Whoop Strain")).to be_nil
    end

    it "returns nil for a blank description" do
      expect(described_class.headline(nil)).to be_nil
      expect(described_class.headline("  \n ")).to be_nil
    end
  end

  describe ".power_block" do
    it "renders all fields, preferring the icu_-prefixed values" do
      activity = { type: "Ride", icu_average_watts: 200.4, icu_weighted_avg_watts: 210.6, icu_intensity: 71.4, icu_training_load: 98 }
      expect(described_class.power_block(activity)).to eq("⚡️ Avg 200 W · NP 211 W · IF 0.71 · TSS 98")
    end

    it "renders only the present fields" do
      expect(described_class.power_block({ type: "Ride", average_watts: 180 })).to eq("⚡️ Avg 180 W")
      expect(described_class.power_block({ type: "Ride", icu_training_load: 55 })).to eq("⚡️ TSS 55")
    end

    it "returns nil without power fields or for non-cycling activities" do
      expect(described_class.power_block({ type: "Ride" })).to be_nil
      expect(described_class.power_block({ type: "Run", icu_average_watts: 300 })).to be_nil
    end
  end

  describe ".heat_block" do
    it "renders HSI and adaptation together" do
      block = described_class.heat_block(max_hsi: 2.5, median_hsi: 1.7, heat_adaptation_score: 72.4, swim: false)
      expect(block).to eq("🌡️ Max HSI 2.5 · Median HSI 1.7 · 72% heat adapted")
    end

    it "requires both HSI values for the HSI part" do
      block = described_class.heat_block(max_hsi: 2.5, median_hsi: nil, heat_adaptation_score: 72, swim: false)
      expect(block).to eq("🌡️ 72% heat adapted")
    end

    it "suppresses a zero or nil adaptation score" do
      expect(described_class.heat_block(max_hsi: nil, median_hsi: nil, heat_adaptation_score: 0, swim: false)).to be_nil
      block = described_class.heat_block(max_hsi: 2.0, median_hsi: 1.0, heat_adaptation_score: nil, swim: false)
      expect(block).to eq("🌡️ Max HSI 2.0 · Median HSI 1.0")
    end

    it "is suppressed entirely for swims" do
      expect(described_class.heat_block(max_hsi: 2.5, median_hsi: 1.7, heat_adaptation_score: 72, swim: true)).to be_nil
    end
  end

  describe ".whoop_block" do
    it "formats the strain to one decimal" do
      expect(described_class.whoop_block(12.42, swim: false)).to eq("🔥 12.4 Whoop Strain")
      expect(described_class.whoop_block(8, swim: false)).to eq("🔥 8.0 Whoop Strain")
    end

    it "is suppressed for swims and nil strain" do
      expect(described_class.whoop_block(12.4, swim: true)).to be_nil
      expect(described_class.whoop_block(nil, swim: false)).to be_nil
    end
  end

  describe ".water_temp_block" do
    it "formats celsius with one decimal" do
      expect(described_class.water_temp_block(15.53, unit: :celsius)).to eq("💧 Water temperature 15.5 °C")
    end

    it "converts to fahrenheit when preferred" do
      expect(described_class.water_temp_block(15.0, unit: :fahrenheit)).to eq("💧 Water temperature 59 °F")
    end

    it "strips a trailing .0 so whole degrees read naturally" do
      expect(described_class.water_temp_block(16.0, unit: :celsius)).to eq("💧 Water temperature 16 °C")
    end

    it "returns nil without a temperature" do
      expect(described_class.water_temp_block(nil, unit: :celsius)).to be_nil
    end
  end

  describe ".compose" do
    it "stacks the stat lines in canonical order" do
      composed = described_class.compose(
        planned: "2 hours of sweet spot",
        weather: "🌤️ Mild and sunny",
        water_temp: "💧 Water temperature 16 °C",
        power: "⚡️ Avg 200 W",
        heat: "🌡️ Max HSI 2.5 · Median HSI 1.7",
        whoop: "🔥 12.4 Whoop Strain"
      )

      expect(composed).to eq(<<~TEXT.strip)
        🗓️ 2 hours of sweet spot
        🌤️ Mild and sunny
        💧 Water temperature 16 °C
        ⚡️ Avg 200 W
        🌡️ Max HSI 2.5 · Median HSI 1.7
        🔥 12.4 Whoop Strain
      TEXT
    end

    it "separates the headline from the stat block with a blank line" do
      expect(described_class.compose(headline: "Felt great.", whoop: "🔥 12.4 Whoop Strain"))
        .to eq("Felt great.\n\n🔥 12.4 Whoop Strain")
    end

    it "returns just the headline when there are no stat lines" do
      expect(described_class.compose(headline: "Felt great.")).to eq("Felt great.")
    end

    it "returns an empty string when there's nothing at all" do
      expect(described_class.compose).to eq("")
    end
  end
end
