# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

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

## MANDATORY WORKFLOW REQUIREMENTS

**ALL agents MUST follow these requirements in order:**

### 1. Tests Must Pass

- **ALWAYS** run `bundle exec rake test` after making changes
- **NEVER** commit code that fails tests
- If tests fail, fix them before proceeding

### 2. Full Build Must Succeed

- **ALWAYS** run `bundle exec rake build:verbose` after making changes
- **NEVER** commit code that fails the build process
- The build process includes: tests → data import → JavaScript build → Middleman build

### 3. Follow EditorConfig Conventions

- **ALWAYS** follow the rules defined in `.editorconfig`

### 4. Lint Code Using Available Tools

- **ALWAYS** run `npm run lint:scss` for SCSS files
- **ALWAYS** run `npm run format:check` for JavaScript, JSON, and Markdown files
- **ALWAYS** fix linting issues before committing
- Use `npm run lint:scss:fix` to auto-fix SCSS issues
- Use `npm run format` to auto-fix formatting issues

### 5. Build JavaScript When Making JS Changes

- **ALWAYS** run `npm run build` after making changes to JavaScript files
- **NEVER** commit JavaScript changes without building them first

## Available Commands

### Rake Commands

#### Core Development

```bash
# Import all data (run this first)
bundle exec rake import

# Run tests (MANDATORY after making changes)
bundle exec rake test

# Full build process
bundle exec rake build

# Build with verbose output (MANDATORY after making changes)
bundle exec rake build:verbose
```

#### Partial Data Import

```bash
# Import specific data types
bundle exec rake import:content    # Contentful
bundle exec rake import:icons      # Font Awesome icons
bundle exec rake import:weather    # Weather, AQI, pollen
bundle exec rake import:whoop      # Whoop data
```

### NPM Commands

#### JavaScript/CSS Development

```bash
# Build JavaScript for production (MANDATORY after JS changes)
npm run build

# Watch for JS/CSS changes during development
npm run watch
```

#### Code Quality

```bash
# Lint SCSS files (MANDATORY)
npm run lint:scss

# Auto-fix SCSS linting issues
npm run lint:scss:fix

# Check formatting for JS/JSON/MD files (MANDATORY)
npm run format:check

# Auto-fix formatting issues
npm run format
```

### Middleman Commands

```bash
# Local development server
bundle exec middleman

# Build site only (without data import)
bundle exec middleman build
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
- `source/stylesheets/` - SCSS stylesheets

### Build Output

- `build/` - Generated static site (git-ignored)

## Development Workflow

### Starting Development

1. **ALWAYS** run `bundle exec rake import` first to get fresh data
2. Run `bundle exec middleman` for the development server
3. In a separate terminal, run `npm run watch` for JavaScript/CSS changes

### Making Changes

1. Make your changes
2. **ALWAYS** run `npm run lint:scss` and `npm run format:check`
3. Fix any linting issues
4. **ALWAYS** run `npm run build` if you changed JavaScript files
5. **ALWAYS** run `bundle exec rake test` after changes
6. **ALWAYS** run `bundle exec rake build:verbose` before committing

### Testing

- Tests are located in `spec/` directory
- Focus on helper methods, text processing, markdown rendering, and data transformation
- Use `bundle exec rake test` to run tests

## Troubleshooting

### Debugging

- Check `data/*.json` files for expected structure
- Use verbose build: `bundle exec rake build:verbose`

Remember: **Tests → Lint → Build → Commit** - this is the mandatory workflow for all changes.
