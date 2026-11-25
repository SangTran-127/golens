# GoLens

GoLens is a native macOS IDE for Go. The interface is SwiftUI and AppKit; the language features run in a Go core linked into the app, with `gopls` and Delve underneath.

## Download

Get the latest `.dmg` from [Releases](https://github.com/SangTran-127/golens/releases/latest) and drag GoLens to Applications.

Requirements: macOS 26 or later on Apple Silicon, and a Go toolchain on the Mac (`go` on your `PATH`).

### First launch

GoLens is signed with its own certificate, not an Apple Developer ID, so macOS blocks the first launch. Open GoLens once, then go to System Settings ▸ Privacy & Security and click **Open Anyway**. Later updates are signed with the same certificate and install through GoLens ▸ Check for Updates… without asking again.

### Linux Sandbox

Running and testing code inside a Linux virtual machine is optional. Install the Linux runtime from Settings ▸ Execution. The runtime is downloaded from this repository's releases, and its manifest is checked against a signing key built into the app before anything is installed. The sources of the GPL components in the runtime are attached to each release.

## Build from source

You need Xcode 26 and Go 1.27.

```sh
make build   # Go core and the app
make run     # build and launch
make test    # Go and Swift tests
```

## About this repository

This repository holds the source of each GoLens release, one commit per release. It is read-only: issues and pull requests are not accepted.

## License

GoLens is licensed under the [Apache License 2.0](LICENSE). Third-party components and their licenses are listed in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and in GoLens ▸ About GoLens ▸ Acknowledgements.
