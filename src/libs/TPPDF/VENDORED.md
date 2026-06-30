# TPPDF — vendored copy

Source: <https://github.com/techprimate/TPPDF>
Upstream commit at vendoring time: **358561e** ("feat: Change to Swift 6 strict concurrency (#424)")

The original `.git` directory has been stripped so the source ships
as plain files in this repo. Update by re-cloning the upstream, then
overlaying the new tree (preserving this VENDORED.md):

```
cd /tmp && git clone https://github.com/techprimate/TPPDF
rsync -a --delete --exclude .git /tmp/TPPDF/ src/libs/TPPDF/
# bump the commit sha above
```

The Swift Package at `src/CleanGmailPDF/Package.swift` references this
copy via `.package(path: "../libs/TPPDF")`.
