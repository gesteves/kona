# Loads every helper module in lib/helpers/ and yields each one.
#
# Both config.rb (which registers them with Middleman) and spec/spec_helper.rb (which includes
# them into the example group) need the same require-and-constantize walk; keeping it in one
# place means a helper can't reach the build without also reaching the specs.
#
# @yieldparam [Module] Each helper module.
def each_kona_helper
  Dir[File.expand_path('helpers/*.rb', __dir__)].sort.each do |file|
    require file
    yield File.basename(file, '.rb').camelcase.constantize
  end
end
