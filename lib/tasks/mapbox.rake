namespace :mapbox do
  desc 'Generate static map images from GPX files in the data/mapbox/gpx folder'
  task generate_images: :environment do
    tileset_id = ENV['TILESET_ID']
    if tileset_id.nil?
      print "Please enter the Mapbox tileset ID: "
      tileset_id = STDIN.gets.chomp
    end

    if tileset_id.empty?
      raise "❎ TILESET_ID is required."
    end

    Dir.glob(File.join(Mapbox::GPX_FOLDER, '*.gpx')).each do |gpx_file|
      options = {
        max_height: ENV['MAX_HEIGHT'],
        min_size: ENV['MIN_SIZE'],
        padding: ENV['PADDING'],
        tileset_id: tileset_id
      }.compact
      mapbox = Mapbox.new(
        gpx_file,
        options
      )
      mapbox.generate_map_image
    end
  end
end
