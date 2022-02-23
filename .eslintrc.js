module.exports = {
  env: {
    browser: false,
    es2021: true,
    mocha: true,
    node: true,
  },
  extends: 'eslint:recommended',
  parserOptions: {
    sourceType: 'module',
    ecmaVersion: 2018,
  },
  globals: {
    express: true,
    rootRequire: true,
    asyncMiddleware: true,
  },
  rules: {
    'no-console': 0,
    'comma-dangle': [ 'error', 'always-multiline' ],
    'object-curly-spacing': [ 2, 'always' ],
    'array-bracket-spacing': [ 2, 'always' ],
    'newline-before-return': 'error',
    indent: [
      'error',
      2,
    ],
    'linebreak-style': [
      'error',
      'unix',
    ],
    quotes: [
      'error',
      'single',
    ],
    semi: [
      'error',
      'always',
    ],
    'arrow-parens': [
      'error',
      'as-needed',
    ],
  },
};
