namespace :mapbox do
  desc 'Generate static map images from GPX files in the data/mapbox/gpx folder'
  task generate_images: :environment do
    Dir.glob(File.join(Mapbox::GPX_FOLDER, '*.gpx')).each do |gpx_file|
      print "❓ Did you add #{File.basename(gpx_file)} to the map in Mapbox Studio and publish it? [y/N]: "
      if STDIN.gets.chomp.downcase == 'y'
        mapbox = Mapbox.new(
          gpx_file,
          max_height: ENV['MAX_HEIGHT']&.to_i || 1280,
          min_size_km: ENV['MIN_SIZE_KM']&.to_f || 0,
          padding: ENV['PADDING']&.to_i || 50
        )
        mapbox.generate_map_image
      else
        puts "Skipping #{File.basename(gpx_file)}…"
      end
    end
  end
end
