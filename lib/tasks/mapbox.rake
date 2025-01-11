namespace :mapbox do
  desc 'Generate static map images from GPX files in the data/mapbox/gpx folder'
  task generate_images: :environment do
    Dir.glob(File.join(Mapbox::GPX_FOLDER, '*.gpx')).each do |gpx_file|
      print "❓ Did you add #{File.basename(gpx_file)} to the map in Mapbox Studio and publish it? [y/N]: "
      if STDIN.gets.chomp.downcase == 'y'
        options = {
          max_height: ENV['MAX_HEIGHT'],
          min_size: ENV['MIN_SIZE'],
          padding: ENV['PADDING']
        }.compact
        mapbox = Mapbox.new(
          gpx_file,
          options
        )
        mapbox.generate_map_image
      else
        puts "Skipping #{File.basename(gpx_file)}…"
      end
    end
  end
end
