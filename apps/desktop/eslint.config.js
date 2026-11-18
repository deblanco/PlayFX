import js from "@eslint/js"
import reactHooks from "eslint-plugin-react-hooks"
import tseslint from "typescript-eslint"

export default tseslint.config(
  { ignores: ["dist", "src-tauri", "src/components/ui", "eslint.config.js"] },
  js.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  ...tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    plugins: { "react-hooks": reactHooks },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // Effect's generator style yields services/effects; these rules misread it.
      "require-yield": "off",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: true }],
      // App code must not throw or use raw promises/JSON.parse — see CLAUDE.md (Effect everywhere).
      "no-restricted-syntax": [
        "error",
        { selector: "TryStatement", message: "Use Effect.try / Effect.tryPromise instead of try/catch." },
        { selector: "CallExpression[callee.object.name='JSON'][callee.property.name='parse']", message: "Decode with Schema.fromJsonString instead of JSON.parse." },
        { selector: "NewExpression[callee.name='Promise']", message: "Model async work as an Effect." },
      ],
    },
  },
  {
    files: ["**/*.test.{ts,tsx}", "src/test/**"],
    rules: { "no-restricted-syntax": "off", "@typescript-eslint/no-non-null-assertion": "off" },
  },
)
