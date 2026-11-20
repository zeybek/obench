# Support

## Which releases get fixes

Before 1.0, only the latest release gets fixes, including security fixes, so upgrade to it to get them. See [STABILITY.md](STABILITY.md) for what a release may change.

## Which Odin versions work

obench supports the oldest Odin release the README names, currently `dev-2026-10`, every Odin release after it, and Odin's nightly build. CI tests the latest Odin release on Linux (x86 and ARM), macOS (ARM and Intel) and Windows on every pull request, `dev-2026-10` on Linux, and the nightly build every night.

When a new Odin release breaks obench, the fix goes into the next obench release. The oldest supported Odin version only moves forward in a release whose notes say so.

## Where to ask

- A bug: open an issue with the bug template, with the output of `odin report` and your obench version.
- An idea or something obench can't measure yet: open an issue with the feature template.
- A question about Odin itself: the [Odin forum](https://forum.odin-lang.org/).
- A security problem: report it privately, as [SECURITY.md](SECURITY.md) describes, not in an issue.
