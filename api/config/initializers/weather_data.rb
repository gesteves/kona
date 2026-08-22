# The lookup tables of the weather widget. They come from the data/*.yml files of the web app, and
# Rails loads them one time at the start. Each key is a symbol: a condition code becomes a symbol,
# for example :Rain, and a Beaufort level stays an integer from 0 to 12, with symbol keys below
# it.
CONDITIONS = YAML.load_file(Rails.root.join("config/conditions.yml"), symbolize_names: true).freeze
BEAUFORT = YAML.load_file(Rails.root.join("config/beaufort.yml"), symbolize_names: true).freeze
