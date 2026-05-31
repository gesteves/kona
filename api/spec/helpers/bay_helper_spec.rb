require "rails_helper"

RSpec.describe BayHelper do
  def bay_helper(goodspeed: nil)
    Class.new { include BayHelper }.new.tap { |h| h.instance_variable_set(:@goodspeed, goodspeed) }
  end

  let(:target) { Time.utc(2024, 6, 1, 12, 0, 0) }

  describe "#bay_conditions_at" do
    it "returns the timeseries entry closest to the given time" do
      goodspeed = DeepOstruct.wrap(timeseries: [
        { t: (target - 300).iso8601,  current_speed_kt: 1.0 },
        { t: (target - 2400).iso8601, current_speed_kt: 0.1 }
      ])
      expect(bay_helper(goodspeed: goodspeed).bay_conditions_at(target).current_speed_kt).to eq(1.0)
    end

    it "returns nil when the closest entry is outside the freshness window" do
      goodspeed = DeepOstruct.wrap(timeseries: [{ t: (target - 2400).iso8601, current_speed_kt: 0.1 }])
      expect(bay_helper(goodspeed: goodspeed).bay_conditions_at(target)).to be_nil
    end

    it "returns nil when there's no bay data" do
      expect(bay_helper.bay_conditions_at(target)).to be_nil
    end
  end

  describe "#bay_current_state" do
    def state_for(speed:, bearing:)
      bay_helper.bay_current_state(DeepOstruct.wrap(current_speed_kt: speed, current_bearing_deg: bearing))
    end

    it "is slack below the slack-current threshold" do
      expect(state_for(speed: 0.1, bearing: 110)).to eq(:slack)
    end

    it "is flood when the current sets toward the flood bearing" do
      expect(state_for(speed: 1.0, bearing: 110)).to eq(:flood)
    end

    it "is ebb when the current sets opposite the flood bearing" do
      expect(state_for(speed: 1.0, bearing: 290)).to eq(:ebb)
    end
  end
end
