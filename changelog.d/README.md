# Changelog fragments

Each pull request that changes what a Lore user sees or can do adds one fragment here. Parallel pull requests then never edit the same lines of `CHANGELOG.md`.

## Write a fragment

1. Name the file `<number>.<type>.md`. `<number>` is the issue the pull request closes, or the pull request number when there is no issue. `<type>` is one of `added`, `changed`, `fixed`, `removed`, or `security`.
2. Write one to three Markdown bullet lines in English. Each line says what the user can now do, or what now works. End each line with the issue reference.

```markdown
- The day inspector shows how much of the day is in meetings. (#32)
```

Pull requests that change only the landing page, documentation, tests, or internal structure add no fragment.

## Check and release

- `python3 Scripts/changelog.py check` validates the fragments. CI runs it.
- `python3 Scripts/changelog.py preview` prints the next release's notes.
- `python3 Scripts/changelog.py release <version>` adds a `<version>` section to `CHANGELOG.md` and deletes the fragments. Commit the result.
