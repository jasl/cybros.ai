import js from "@eslint/js"
import globals from "globals"

const unusedRules = {
  "no-unused-vars": [
    "error",
    {
      argsIgnorePattern: "^_",
      varsIgnorePattern: "^_",
      caughtErrorsIgnorePattern: "^_",
    },
  ],
  "no-empty": ["error", { allowEmptyCatch: true }],
}

export default [
  {
    ignores: [
      "app/assets/builds/**",
      "coverage/**",
      "log/**",
      "node_modules/**",
      "public/**",
      "tmp/**",
      "vendor/**",
    ],
  },
  js.configs.recommended,
  {
    files: ["app/javascript/**/*.js", "test/js/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        ...globals.browser,
        ...globals.node,
      },
    },
    rules: unusedRules,
  },
  {
    // The compose builder library: a classic script evaluated inside a
    // host-less isolate (no browser, no node — it deletes its own clock),
    // so it declares no globals and is linted as a script, not a module.
    files: ["lib/nexus/compose/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "script",
      globals: {},
    },
    rules: unusedRules,
  },
]
