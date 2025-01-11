namespace :mapbox do
  desc 'Generate static map images from GPX files in the data/mapbox/gpx folder'
  task generate_images: :environment do
    global_tileset_id = ENV['TILESET_ID']

    Dir.glob(File.join(Mapbox::GPX_FOLDER, '*.gpx')).each do |gpx_file|
      mapbox = Mapbox.new(gpx_file, { max_height: ENV['MAX_HEIGHT'], min_size: ENV['MIN_SIZE'], padding: ENV['PADDING'] }.compact)
      
      tileset_id = global_tileset_id
      if tileset_id.nil?
        print "Enter the Mapbox tileset ID for #{mapbox.activity_name}, or press Enter to skip: "
        tileset_id = STDIN.gets.chomp
        if tileset_id.empty?
          puts "⏭️  Skipping #{mapbox.activity_name}.\n\n"
          next
        end
      end

      mapbox.tileset_id = tileset_id
      begin
        mapbox.generate_map_image
      rescue => e
        puts "❎ Error generating map for #{mapbox.activity_name}: #{e.message}"
        next
      end   
    end
    puts "✅ All maps generated!"
  end
end
