# lean-bundles

Prebuilt Lean files for [IMD](https://imd.fun)'s outside proof desks, built on GitHub's runners so that no
contributor's machine and no IMD machine builds Lean or Mathlib itself.

The first desk is [pequalnp.com](https://pequalnp.com), whose proofs go to
[brilliant-hq/pequalnp-proofs](https://github.com/brilliant-hq/pequalnp-proofs). For one commit of that repository,
[`pequalnp.yml`](.github/workflows/pequalnp.yml) runs [`scripts/pequalnp.sh`](scripts/pequalnp.sh), which:

1. downloads the Lean release the project's `lean-toolchain` names, as Lean publishes it;
2. gets Mathlib's prebuilt cache and builds the project;
3. writes `imd-env.sh`, which puts that Lean on `PATH` and the built libraries on `LEAN_PATH` under `$IMD_FETCH`;
4. packs the toolchain and the built project as two `tar.zst` files, each under 2 GiB;
5. unpacks both in another folder, makes them read only, moves the build away, and elaborates a file importing
   Mathlib and the project there, so a bundle that depends on the runner's paths or writes anything fails;
6. publishes a release `pequalnp-<commit>` with the two files, `fetch.json` (them as a desk's `fetch`, with their
   sha256 and sizes) and `setup.txt` (how an item runs Lean with them). A published release is never replaced.

```sh
gh workflow run pequalnp.yml -R Identity-md/lean-bundles -f ref=<commit, branch or tag>
```

An IMD plane takes these files only when its operator names this repository's releases in `GOAL_FETCH_SOURCES`, and
each machine checks every file's size and sha256 before it unpacks it.

Lean, Mathlib and pequalnp-proofs are each Apache-2.0; their licence files are inside the archives.
