# Add obench to a project

obench is one folder of Odin files that depends on `base:` and `core:` only. Pick the way of adding it that matches how you update your other dependencies.

## Copy the folder

Copy the `obench` folder of this repository into your project, for example as `libs/obench`, and import it by path:

```odin
import obench "../libs/obench"
```

Each [release](https://github.com/zeybek/obench/releases) has the folder as `obench-<tag>-library.tar.gz` and `.zip`, with the license. Releases after 0.3.0 carry an attestation for every archive, so this checks that a download was built by the release workflow of this repository:

```sh
gh attestation verify obench-<tag>-library.tar.gz -R zeybek/obench
```

To update, replace the folder with the one from a newer release.

## Pin a git subtree to a release

A subtree keeps the repository in your history, pinned to a tag, and needs nothing extra to clone:

```sh
git subtree add --prefix=libs/obench https://github.com/zeybek/obench v0.3.0 --squash
```

The library is then the folder inside it, so the import is `"../libs/obench/obench"`. The CLI skips the examples and tests of a copy like this. To move to another release:

```sh
git subtree pull --prefix=libs/obench https://github.com/zeybek/obench <tag> --squash
```

## Pin a git submodule to a release

A submodule keeps the repository out of your history, and everyone who clones your project has to run `git submodule update --init`:

```sh
git submodule add https://github.com/zeybek/obench libs/obench
git -C libs/obench checkout v0.3.0
git add libs/obench
```

The import is `"../libs/obench/obench"`, as with a subtree.

## Share one copy through a collection

To use one copy from several packages without relative paths, point a collection at the folder that holds it and import `libs:obench`. Pass the same collection to the compiler and to the CLI:

```sh
odin run my_bench -collection:libs=path/to/libs
obench . --collection libs=path/to/libs
```

If an `ols.json` already names the collection for the language server, `--ols` adds its collections for you. The CLI looks for the nearest `ols.json` above each package, up to the root of the git repository, and prints the collections it added:

```json
{"collections": [{"name": "libs", "path": "./libs"}]}
```

## Keep the CLI and the library on the same version

A prebuilt CLI and the library you added are two separate copies. The CLI reads the `VERSION` of the library each package imports and warns when it differs from its own. The runner it generates calls the library, so a mismatch can make the build fail, or the run behave differently, with an error that says nothing about versions.
