# Loads each helper module in lib/helpers/ and gives each one to the block.
#
# config.rb registers them with Middleman, and spec/spec_helper.rb puts them in the example group.
# Both need the same require and constant lookup. This code is in one place, thus a helper cannot
# reach the build and not reach the specs.
#
# @yieldparam [Module] Each helper module.
def each_kona_helper
  Dir[File.expand_path("helpers/*.rb", __dir__)].sort.each do |file|
    require file
    yield File.basename(file, ".rb").camelcase.constantize
  end
end
