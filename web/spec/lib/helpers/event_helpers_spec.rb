require 'spec_helper'
require 'ostruct'
require 'padrino-helpers'

RSpec.describe EventHelpers do
  include_context 'default helper stubs'

  # The content_tag and link_to of Padrino, which event_timestamp_tag uses for its markup.
  include Padrino::Helpers

  # A replacement for the icon code. The true code reads data/icons.json.
  def icon_svg(*) = '<svg></svg>'

  # The timezone from the configuration of the site. The group that tests the default value
  # replaces it.
  def site_time_zone = 'America/Denver'

  # Makes an event double with the shape of a `data.events` entry.
  def event(id:, date:, going: true, title: 'A Race', location: 'Somewhere', url: nil, summary: nil)
    OpenStruct.new(
      sys: OpenStruct.new(id: id),
      title: title,
      summary: summary,
      location: location,
      url: url,
      date: date,
      going: going
    )
  end

  # `data.events`, in the shape that the helpers read.
  def data = OpenStruct.new(events: @events || [])

  # Sets "today", thus the test can check the limit of today or later. It replaces the private
  # method of the module, which reads the clock in the timezone of the site.
  def event_today = Date.new(2026, 6, 15)

  describe '#upcoming_races' do
    it 'lists confirmed events today or later, soonest first' do
      @events = [
        event(id: 'c', date: '2026-08-01T07:00:00-06:00'),
        event(id: 'a', date: '2026-06-20T07:00:00-06:00'),
        event(id: 'b', date: '2026-07-04T07:00:00-06:00')
      ]
      expect(upcoming_races.map { |e| e.sys.id }).to eq(%w[a b c])
    end

    # `going` is the flag that says that the owner races this event. The api uses it to select the
    # events, thus the build must also use it. If it does not, the two lists are different when the
    # widget replaces the section.
    it 'drops events the owner is not going to' do
      @events = [
        event(id: 'skipped', date: '2026-06-20T07:00:00-06:00', going: false),
        event(id: 'racing', date: '2026-07-04T07:00:00-06:00')
      ]
      expect(upcoming_races.map { |e| e.sys.id }).to eq([ 'racing' ])
    end

    it 'includes an event happening today and drops yesterday' do
      @events = [
        event(id: 'past', date: '2026-06-14T07:00:00-06:00'),
        event(id: 'today', date: '2026-06-15T07:00:00-06:00')
      ]
      expect(upcoming_races.map { |e| e.sys.id }).to eq([ 'today' ])
    end

    it 'caps the list at the api\'s unfeatured take' do
      @events = (7..12).map { |m| event(id: "e#{m}", date: format('2026-%02d-01T07:00:00-06:00', m)) }
      expect(upcoming_races.size).to eq(described_class::UPCOMING_RACES_COUNT)
    end

    # ⚠️ Contentful can hold an event with no date, and this code runs on the render path of the home
    # page. One bad entry must remove its own card, and not the full page.
    it 'drops an event with a missing or unparseable date rather than raising' do
      @events = [
        event(id: 'undated', date: nil),
        event(id: 'garbage', date: 'not a date'),
        event(id: 'good', date: '2026-07-04T07:00:00-06:00')
      ]
      expect(upcoming_races.map { |e| e.sys.id }).to eq([ 'good' ])
    end

    it 'returns nothing when there are no events' do
      @events = []
      expect(upcoming_races).to eq([])
    end
  end

  describe '#event_collection_variant' do
    # This is the same as the event_collection_variant of the api when there is no featured event. A
    # difference changes the layout of the section when the widget replaces it.
    it 'matches the api layout variant for each count' do
      expect(event_collection_variant(1)).to eq('single')
      expect(event_collection_variant(2)).to eq('halves')
      expect(event_collection_variant(3)).to eq('thirds')
      expect(event_collection_variant(4)).to eq('thirds')
    end
  end

  describe '#event_timestamp_tag' do
    it 'renders a machine-readable <time> alongside the calendar icon' do
      markup = event_timestamp_tag(event(id: 'a', date: '2026-07-04T07:00:00-06:00'))
      expect(markup).to include('<time datetime="2026-07-04">July 4, 2026</time>')
    end

    it 'renders nothing for an undated event' do
      expect(event_timestamp_tag(event(id: 'a', date: nil))).to eq('')
    end
  end

  describe '#events_schema' do
    it 'builds one SportsEvent node per listed race' do
      races = [ event(id: 'a', date: '2026-07-04T07:00:00-06:00', title: 'Big Race',
                      location: 'Jackson, WY', url: 'https://example.org/race', summary: 'A race.') ]
      node = JSON.parse(events_schema(races)).first

      expect(node).to include(
        '@type' => 'SportsEvent',
        'name' => 'Big Race',
        'startDate' => '2026-07-04',
        'eventStatus' => 'https://schema.org/EventScheduled',
        'url' => 'https://example.org/race',
        'description' => 'A race.'
      )
      # An event rich result needs `address`. The location is one line of free text, thus the name
      # and the address are the same string.
      expect(node['location']).to eq('@type' => 'Place', 'name' => 'Jackson, WY', 'address' => 'Jackson, WY')
      # The author competes and does not organize. @id points to the author, thus each reference
      # goes to the one sitewide Person node.
      expect(node['performer']).to eq('@id' => 'https://example.com/about#person')
    end

    it 'omits fields the event does not carry' do
      node = JSON.parse(events_schema([ event(id: 'a', date: '2026-07-04T07:00:00-06:00', location: nil) ])).first
      expect(node).not_to have_key('location')
      expect(node).not_to have_key('url')
      expect(node).not_to have_key('description')
    end

    it 'returns nil when nothing has a usable date' do
      expect(events_schema([ event(id: 'a', date: nil) ])).to be_nil
      expect(events_schema([])).to be_nil
    end
  end
end
