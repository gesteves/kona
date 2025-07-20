# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Core Architecture

Kona is a static site generator built on **Middleman** that creates a blog powered by **Contentful**. The architecture follows a data-driven approach where external APIs are fetched at build time and cached as JSON files.

### Key Design Patterns

- **Data Layer**: All external data (CMS content, weather, activity stats) is fetched via rake tasks and stored in `data/*.json` files
- **Proxy System**: Middleman uses data files to generate pages dynamically via proxies (articles, pages, tags)
- **Helper Architecture**: Business logic is organized in modular helpers in `lib/helpers/`
- **Component Structure**: ERB partials in `source/partials/` provide reusable UI components
- **Asset Pipeline**: Webpack handles JavaScript bundling, Sass for stylesheets

### Data Flow

1. `rake import` fetches data from external APIs (Contentful, WeatherKit, Google APIs, etc.)
2. Data is cached in Redis and saved as JSON files in `data/`
3. Middleman reads JSON data files and generates static pages via proxies
4. ERB templates use helper methods to render content and components

## Essential Commands

### Development

```bash
# Import data without rebuilding site
bundle exec rake import

# Run tests
bundle exec rake test
# or
bundle exec rspec

# Local development server
bundle exec middleman

# Watch for JS/CSS changes
npm run watch

# JS build with webpack
npm run build
```

### Build Process

```bash
# Production build used by Netlify
bundle exec rake build
```

### Partial Data Import

```bash
# Import specific data types
bundle exec rake import:content    # Contentful
bundle exec rake import:weather    # Weather, AQI, pollen
bundle exec rake import:icons      # Font Awesome icons
```

## Key File Locations

### Configuration

- `config.rb` - Middleman configuration and proxy setup
- `netlify.toml` - Netlify build settings and redirects
- `Rakefile` - Main rake tasks and Redis setup

### Data Layer

- `lib/data/*.rb` - API client classes for external services
- `lib/tasks/import.rake` - Data import orchestration
- `data/*.json` - Generated data files (git-ignored)

### Frontend Code

- `source/layouts/layout.erb` - Main layout template
- `source/partials/` - Reusable ERB components
- `lib/helpers/` - Ruby helper methods for templates
- `source/javascripts/stimulus/` - Stimulus controllers for interactivity

### Build Output

- `build/` - Generated static site (git-ignored)

## Testing

The project uses RSpec for testing helper methods and utilities. Tests are located in `spec/` and focus on:

- Helper method functionality
- Text processing utilities
- Markdown rendering
- Data transformation logic

## Development Notes

### Data Import Dependencies

Many data sources have dependencies on each other:

- Weather data requires location data from Google Maps
- Purple Air AQI requires location and weather setup
- TrainerRoad requires timezone data from Google Maps

### Cache Strategy

The project uses Redis caching to speed up API calls during development and builds. Cache keys are typically based on API endpoints and parameters.

### Environment Variables

Extensive environment configuration is required for all external services. Check `.env.example` or README for required variables.

## Code Style

- Follow the rules defined in `.editorconfig`
