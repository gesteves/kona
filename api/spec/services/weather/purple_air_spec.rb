require "rails_helper"

RSpec.describe PurpleAir do
  subject(:service) { described_class.new(37.77, -122.42) }

  # The EPA correction uses three formulas, one for each band. The transition bands, which are 30 to
  # 50 and 210 to 260 µg/m³, mix two of them with a weight that goes from 0 to 1. A person
  # calculated each expected value from the published formulas.
  describe "#apply_epa_correction" do
    def correct(pm25, humidity)
      service.send(:apply_epa_correction, pm25, humidity)
    end

    let(:humidity) { 40 }

    it "returns nil when pm2.5 is blank" do
      expect(correct(nil, humidity)).to be_nil
    end

    it "returns the raw pm2.5 when humidity is blank" do
      expect(correct(12.0, nil)).to eq(12.0)
    end

    it "applies the low-concentration formula below 30 µg/m³" do
      # 0.524 * 10 - 0.0862 * 40 + 5.75
      expect(correct(10.0, humidity)).to be_within(0.001).of(7.542)
    end

    it "blends low and mid formulas across the 30–50 µg/m³ band" do
      # w = 40/20 - 1.5 = 0.5, thus (0.786 * 0.5 + 0.524 * 0.5) * 40 - 0.0862 * 40 + 5.75
      expect(correct(40.0, humidity)).to be_within(0.001).of(28.502)
    end

    it "is continuous at the 30 µg/m³ boundary (blend weight 0 → low formula)" do
      low = 0.524 * 30.0 - 0.0862 * humidity + 5.75
      expect(correct(30.0, humidity)).to be_within(0.001).of(low)
    end

    it "applies the mid-concentration formula between 50 and 210 µg/m³" do
      # 0.786 * 100 - 0.0862 * 40 + 5.75
      expect(correct(100.0, humidity)).to be_within(0.001).of(80.902)
    end

    it "blends mid and high formulas across the 210–260 µg/m³ band" do
      # w = 235/50 - 4.2 = 0.5
      expect(correct(235.0, humidity)).to be_within(0.001).of(200.473)
    end

    it "is continuous at the 210 µg/m³ boundary (blend weight 0 → mid formula)" do
      mid = 0.786 * 210.0 - 0.0862 * humidity + 5.75
      expect(correct(210.0, humidity)).to be_within(0.001).of(mid)
    end

    it "applies the high-concentration formula at 260 µg/m³ and above" do
      # 2.966 + 0.69 * 300 + 8.84e-4 * 300**2
      expect(correct(300.0, humidity)).to be_within(0.001).of(289.526)
    end

    it "is continuous at the 260 µg/m³ boundary (blend weight 1 → high formula)" do
      high = 2.966 + 0.69 * 260.0 + 8.84e-4 * 260.0**2
      expect(correct(260.0, humidity)).to be_within(0.001).of(high)
    end

    # A sensor gives a small negative PM2.5 value in clean air. The correction does not apply there,
    # and without a minimum, such a value goes past each band to the polynomial for a high
    # concentration and gives a dangerous result.
    it "clamps a negative reading to zero rather than treating it as high-concentration" do
      expect(correct(-2.0, humidity)).to eq(0.0)
    end

    it "handles integer inputs without integer-division truncation" do
      expect(correct(40, humidity)).to be_within(0.001).of(28.502)
    end
  end
end
