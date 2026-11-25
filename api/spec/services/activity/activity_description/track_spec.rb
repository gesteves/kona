require "rails_helper"

RSpec.describe ActivityDescription::Track do
  # A track with one point at each time, in seconds. Each point is 0.001° of latitude (about
  # 111 m) north of the point before it, times the step that the block gives.
  def track(times, &step)
    step ||= ->(_index) { 1 }
    latitude = 46.0
    latitudes = times.each_index.map { |index| latitude += 0.001 * step.call(index) }
    described_class.new([ { type: "time", data: times }, { type: "latlng", data: latitudes, data2: times.map { -119.0 } } ])
  end

  it "gives no points, no samples, and no legs with no position stream" do
    empty = described_class.new([ { type: "time", data: [ 0, 60 ] } ])

    expect(empty.points).to eq([])
    expect(empty.samples).to eq([])
    expect(empty.legs).to eq([])
  end

  it "omits a point with no position, and gives each point its distance along the track" do
    streams = [
      { type: "time", data: [ 0, 60, 120 ] },
      { type: "latlng", data: [ 46.0, nil, 46.002 ], data2: [ -119.0, -119.0, -119.0 ] }
    ]
    points = described_class.new(streams).points

    expect(points.map { |point| point[:index] }).to eq([ 0, 2 ])
    expect(points.first[:meters]).to eq(0.0)
    expect(points.last[:meters]).to be_within(1).of(222.4)
  end

  it "takes one sample each minute, and each sample counts for the time around it" do
    samples = track((0..300).step(30).to_a).samples

    expect(samples.map { |sample| sample[:offset] }).to eq([ 0, 60, 120, 180, 240, 300 ])
    expect(samples.map { |sample| sample[:seconds] }).to eq([ 30.0, 60.0, 60.0, 60.0, 60.0, 30.0 ])
  end

  it "also takes the last point as a sample" do
    samples = track([ 0, 60, 90 ]).samples

    expect(samples.map { |sample| sample[:offset] }).to eq([ 0, 60, 90 ])
    expect(samples.sum { |sample| sample[:seconds] }).to eq(90.0)
  end

  it "gives the one sample of a track of one moment a weight" do
    expect(track([ 0 ]).samples.map { |sample| sample[:seconds] }).to eq([ 1.0 ])
  end

  it "makes one leg for each 50 m, with its bearing and its moving time" do
    legs = track([ 0, 60, 120 ]).legs

    expect(legs.size).to eq(2)
    expect(legs.map { |leg| leg[:offset] }).to eq([ 0, 60 ])
    expect(legs.map { |leg| leg[:seconds] }).to eq([ 60.0, 60.0 ])
    expect(legs.first[:bearing]).to be_within(0.01).of(0.0)
  end

  it "does not count a stop as moving time" do
    stopped_first = track([ 0, 60, 120 ]) { |index| index == 1 ? 0 : 1 }

    expect(stopped_first.legs.sum { |leg| leg[:seconds] }).to eq(60.0)
  end
end
