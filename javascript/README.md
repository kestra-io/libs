# Kestra JavaScript Libs

This project includes the following tools:

- [Prettier](https://prettier.io/): Formatting
- [Eslint](https://eslint.org/): Linting
- [Vitest](https://vitest.dev/): Testing
- [Rollup](https://rollupjs.org/): Bundling

---

### Development

```bash
# Install dependencies
$ npm i
```

---

### Build

```bash
# Builds the source code and bundles it using rollup for distribution to npm
$ npm run build
```

---

### Testing

```bash
# Runs vitest
$ npm run test

# Runs vitest with GUI
$ npm run test:ui
```

You can test this library using npm symlinks before publishing to npm.

This can be done using the following steps:

```bash
# Create a symlink for this project to global node_modules
$ npm link

# Lists all global symlinks. You can also use this command to check if your symlink worked.
$ npm ls -g --depth=0 --link=true

# Navigate to a different project and symlink this project. NOTE: that project must also be using npm as a package manager.
$ npm link @kestra-io/libs

# Once you are done with testing, you can remove the symlink. NOTE: this will also remove the dependency in package.json so you will need to reinstall the package again.
$ npm unlink @kestra-io/libs

# Unlink the package globally to remove the symlink
$ npm unlink --global @kestra-io/libs
```

---
