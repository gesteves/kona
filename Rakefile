require 'dotenv/tasks'
require 'rake/clean'
require 'redis'
require_relative 'lib/helpers/task_helpers'
include TaskHelpers

# Require all Ruby files in the lib/data directory
Dir["lib/data/*.rb"].each { |file| require_relative file }

DATA_DIRECTORY = 'data'
BUILD_DIRECTORY = 'build'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

# Import tasks from lib/tasks
Dir.glob('lib/tasks/**/*.rake').each { |r| import r }
