const path = require('path');

module.exports = {
  mode: 'development',
  entry: './source/javascripts/stimulus/index.js',
  output: {
    filename: 'site.js',
    path: path.resolve(__dirname, 'source/javascripts')
  },
  module: {
    rules: [
      {
        test: /\.js$/,
        exclude: /node_modules/,
        use: {
          loader: 'babel-loader',
          options: {
            presets: ['@babel/preset-env']
          }
        }
      }
    ]
  }
};
