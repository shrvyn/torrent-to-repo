# Torrent-to-repo (GitHub Actions)

This project turns a torrent into 2 GiB parts and commits them to a GitHub
repository using **GitHub Actions**. You provide a magnet URI or `.torrent`
URL; the workflow downloads it (with aria2c), chunks it into
`<Name>.part0001` … parts, writes per-file `<Name>.manifest.json` files with
SHA-256 hashes of the parts and of the original file, and pushes everything to
the repository that runs the workflow.

## Usage

1. This repository is the starting point. Clone or use it as the base of a new
   repo ("Torrent-to-repo").
2. Open the repo on GitHub → **Actions** → workflow **`torrent-to-repo`** →
   **Run workflow**.
3. Provide:
   - `source` – magnet URI or .torrent URL (required),
   - `target_branch` – branch to commit to (optional; default = the repo's
     default branch),
   - `chunk_size_mb` – part size in MB (default: 2048, i.e. 2 GiB).
4. Watch the run. When it finishes, the parts + manifests are committed to the
   repository.

Example of the resulting layout after a run:

```
downloads/
  SomeMovie.mkv.part0001      (2 GiB)
  SomeMovie.mkv.part0002      (2 GiB)
  SomeMovie.mkv.part0003      (rest)
  SomeMovie.mkv.manifest.json
```

## The pieces

- `.github/workflows/torrent-to-repo.yml` – the GitHub Actions workflow.
- `Torrent-To-GitHub.ps1` – the chunker used by the workflow (also usable
  locally: `Torrent-To-GitHub.ps1 -Source <dir> -SkipDownload -SkipGitHub`).
- `Reassemble.ps1` – rebuild the original files from the parts + manifests.

## Reassemble the original files

```powershell
.\Reassemble.ps1 -ManifestPath "C:\...\SomeMovie.mkv.manifest.json"
```

It appends the parts in order, verifies the per-part SHA-256 hashes and the
reassembled file's SHA-256, and reports any mismatch.

## Notes / requirements

- The runner (`windows-latest`) needs enough free disk space for the torrent
  download plus the parts (roughly 2x the torrent size).
- Per repo quotas apply: GitHub repos have storage limits; keep an eye on how
  much you host.
- Torrents are as lawful as the content they fetch — see the note in the
  original project README; this tool only moves data.
- The commit is done with the repo's `GITHUB_TOKEN` (`contents: write`).
