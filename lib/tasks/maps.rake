require_relative '../utils/static_map'
namespace :maps do
  desc 'Generate static map images from GPX files in the data/maps/gpx folder'
  task generate: :environment do
    global_tileset_id = ENV['TILESET_ID']

    Dir.glob(File.join(StaticMap::GPX_FOLDER, '*.gpx')).each do |gpx_file|
      map = StaticMap.new(gpx_file, { max_height: ENV['MAX_HEIGHT'], min_size: ENV['MIN_SIZE'] }.compact)
      
      tileset_id = global_tileset_id
      if tileset_id.nil?
        print "Enter the Mapbox tileset ID for #{map.activity_title}, or press Enter to skip: "
        tileset_id = STDIN.gets.chomp
        if tileset_id.empty?
          puts "⏭️  Skipping #{map.activity_title}.\n\n"
          next
        end
      end

      map.tileset_id = tileset_id
      begin
        map.generate_map_image
      rescue => e
        puts "❎ Error generating map for #{map.activity_title}: #{e.message}"
        next
      end   
    end
    puts "✅ All maps generated!"
  end
end
