require 'spec_helper'

RSpec.describe EventsHelpers do
  let(:test_class) do
    Class.new do
      include EventsHelpers
      include LocationHelpers
      attr_accessor :data
    end
  end
  let(:test_instance) { test_class.new }
  
  let(:mock_data) { double('data') }
  let(:mock_events) { [] }
  let(:mock_articles) { [] }
  let(:mock_event) { double('event') }

  before do
    test_instance.data = mock_data
    allow(mock_data).to receive(:events).and_return(mock_events)
    allow(mock_data).to receive(:articles).and_return(mock_articles)
    # Setup location and time mocks since these come from dependencies
    allow(test_instance.data).to receive(:location).and_return(double('location', 
      time_zone: double('time_zone', time_zone_id: 'America/Denver')))
    allow(test_instance).to receive(:current_time).and_return(Time.parse('2024-01-15 12:00:00 -0700'))

    # Setup event mock
    allow(mock_event).to receive(:blank?).and_return(false)
    allow(mock_event).to receive(:date).and_return('2024-01-15T10:00:00Z')
    allow(mock_event).to receive(:going).and_return(true)
    allow(mock_event).to receive(:tracking_url).and_return(nil)
    allow(mock_event).to receive(:title).and_return('Test Race')
    allow(mock_event).to receive(:sys).and_return(double('sys', id: 'event123'))
  end

  describe "#is_today?" do
    it "returns true when event is today" do
      expect(test_instance.is_today?(mock_event)).to be true
    end

    it "returns false when event is blank" do
      expect(test_instance.is_today?(nil)).to be false
    end

    it "returns false when event is not today" do
      allow(mock_event).to receive(:date).and_return('2024-01-16T10:00:00Z')
      expect(test_instance.is_today?(mock_event)).to be false
    end
  end

  describe "#todays_race" do
    let(:mock_events) { [mock_event] }

    it "returns today's race event" do
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(true)
      expect(test_instance.todays_race).to eq(mock_event)
    end

    it "returns nil when no race is today" do
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(false)
      expect(test_instance.todays_race).to be_nil
    end

    it "returns nil when today's event is not confirmed going" do
      allow(mock_event).to receive(:going).and_return(false)
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(true)
      expect(test_instance.todays_race).to be_nil
    end
  end

  describe "#is_race_day?" do
    it "returns true when there's a race today" do
      allow(test_instance).to receive(:todays_race).and_return(mock_event)
      expect(test_instance.is_race_day?).to be true
    end

    it "returns false when there's no race today" do
      allow(test_instance).to receive(:todays_race).and_return(nil)
      expect(test_instance.is_race_day?).to be false
    end
  end

  describe "#is_close?" do
    it "returns true when event is within 10 days" do
      allow(mock_event).to receive(:date).and_return('2024-01-20T10:00:00Z')
      expect(test_instance.is_close?(mock_event)).to be true
    end

    it "returns false when event is blank" do
      expect(test_instance.is_close?(nil)).to be false
    end

    it "returns false when event is in the past" do
      allow(mock_event).to receive(:date).and_return('2024-01-10T10:00:00Z')
      expect(test_instance.is_close?(mock_event)).to be false
    end
  end

  describe "#is_in_progress?" do
    before do
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(true)
    end

    it "returns true when event is today and confirmed going" do
      expect(test_instance.is_in_progress?(mock_event)).to be true
    end

    it "returns false when event is not today" do
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(false)
      expect(test_instance.is_in_progress?(mock_event)).to be false
    end

    it "returns false when event is not confirmed going" do
      allow(mock_event).to receive(:going).and_return(false)
      expect(test_instance.is_in_progress?(mock_event)).to be false
    end

    it "returns false when event is blank" do
      expect(test_instance.is_in_progress?(nil)).to be false
    end
  end

  describe "#is_trackable?" do
    before do
      allow(test_instance).to receive(:is_in_progress?).with(mock_event).and_return(true)
      allow(mock_event).to receive(:tracking_url).and_return('http://example.com/track')
    end

    it "returns true when event is in progress and has tracking URL" do
      expect(test_instance.is_trackable?(mock_event)).to be true
    end

    it "returns false when event is not in progress" do
      allow(test_instance).to receive(:is_in_progress?).with(mock_event).and_return(false)
      expect(test_instance.is_trackable?(mock_event)).to be false
    end

    it "returns false when event has no tracking URL" do
      allow(mock_event).to receive(:tracking_url).and_return(nil)
      expect(test_instance.is_trackable?(mock_event)).to be false
    end

    it "returns false when event is blank" do
      expect(test_instance.is_trackable?(nil)).to be false
    end
  end

  describe "#event_timestamp" do
    it "returns 'Today' when event is today" do
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(true)
      expect(test_instance.event_timestamp(mock_event)).to eq('Today')
    end

    it "returns formatted date when event is not today" do
      allow(test_instance).to receive(:is_today?).with(mock_event).and_return(false)
      allow(mock_event).to receive(:date).and_return('2024-02-14T10:00:00Z')
      expect(test_instance.event_timestamp(mock_event)).to eq('February 14, 2024')
    end
  end

end
