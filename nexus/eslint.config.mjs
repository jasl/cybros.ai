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
]
