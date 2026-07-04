require "rails_helper"

RSpec.describe WorkoutsHelper do
  let(:helper) { Class.new { include WorkoutsHelper }.new }

  it "reports a scheduled workout when workouts are present" do
    workouts = [double("workout")]
    expect(helper.workout_scheduled?(workouts)).to be true
    expect(helper.rest_day?(workouts)).to be false
  end

  it "reports a rest day when there are no workouts" do
    expect(helper.workout_scheduled?([])).to be false
    expect(helper.rest_day?([])).to be true
  end

  it "reports a rest day when workouts are nil" do
    expect(helper.rest_day?(nil)).to be true
  end
end
