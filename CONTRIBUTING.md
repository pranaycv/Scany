# Contributing

Bugs and small fixes are welcome. Open an issue first for anything that
changes scanning behavior, the privacy story, or the cloud export flow.

## Build

Follow the README. You need Xcode 15 or newer and a physical iPhone on
iOS 15 or later. The Simulator can open the app, but it cannot exercise
live page detection.

## What not to commit

- OAuth refresh tokens, service-account keys, or a Google client secret.
  The iOS client ID already in the tree is a public client restricted to
  bundle ID `com.prnysoni.Scany`. It is not a secret.
- Training photos, model weights, or Hugging Face caches under
  `segmentation-experiment/` (`Train/`, `data/`, `models/`, `.venv/`).
- Apple signing keys, provisioning profiles, or `xcuserdata`.

## License of contributions

This project is under the [PolyForm Noncommercial License 1.0.0](LICENSE).
By submitting a contribution, you agree that it may be used under those
same terms, including the required notice in `LICENSE`. Commercial use
is not granted.

Required Notice: Copyright Pranay Soni (https://github.com/pranaycv)
