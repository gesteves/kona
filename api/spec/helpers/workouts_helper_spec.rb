require "rails_helper"

RSpec.describe WorkoutsHelper do
  def helper_with(workouts)
    Class.new { include WorkoutsHelper }.new.tap { |h| h.instance_variable_set(:@workouts, workouts) }
  end

  it "reports a scheduled workout when @workouts is present" do
    helper = helper_with([double("workout")])
    expect(helper.is_workout_scheduled?).to be true
    expect(helper.is_rest_day?).to be false
  end

  it "reports a rest day when @workouts is empty" do
    helper = helper_with([])
    expect(helper.is_workout_scheduled?).to be false
    expect(helper.is_rest_day?).to be true
  end

  it "reports a rest day when @workouts is nil" do
    expect(helper_with(nil).is_rest_day?).to be true
  end
end
