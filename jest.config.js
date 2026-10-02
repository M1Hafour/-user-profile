module.exports = {
  testEnvironment: 'node',
  collectCoverage: true,
  coverageDirectory: 'coverage',
  collectCoverageFrom: ['app.js', 'models/**/*.js'],
  reporters: [
    'default',
    ['jest-junit', { outputDirectory: '.', outputName: 'junit.xml' }],
  ],
};
