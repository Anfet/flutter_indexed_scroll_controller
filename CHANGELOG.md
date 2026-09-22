# Changelog

All notable changes to this package are documented here. This project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Breaking changes

- None.

### Fixed

- Fixed `ScrollAlignmentTarget.row` not including the trailing separator's extent, causing it to land at the same offset as `ScrollAlignmentTarget.item` whenever `alignment != 0`.

## 0.3.1

### Breaking changes

- Raised minimum Flutter requirement from `>=3.19.0` to `>=3.44.0`. The
  previous constraint was unproven: the package already required the stable
  `ScrollCacheExtent` API introduced in Flutter 3.44 and failed to compile
  below it.
- `IndexedScrollItem`, `IndexedScrollSeparator`, and
  `targetPixelsEstimateForStallCheck` are no longer public. They were
  internal implementation details with no supported consumer use case; use
  `IndexedScrollController.watch`/`.separator()` instead.

### Fixed

- Fixed layout reconciliation after row-size changes detected by fingerprints or manual invalidation.
- Fixed `alignment: 0` after a changed prefix is discovered during search.

## 0.3.0

### Added

- Added support for preceding slivers in `CustomScrollView`.
- Added `separator()` and `ScrollAlignmentTarget` for `ListView.separated`.

### Changed

- Made search and measurement steps immediate; `duration` applies to the final scroll.

## 0.2.0

### Added

- Added fingerprint-based measurement invalidation, padding, and reversed-list support.

## 0.1.0

### Added

- Added horizontal lists and gesture-priority cancellation.

### Fixed

- Clamped completed scroll offsets to physical bounds.

## 0.0.1

### Added

- Initial release.
