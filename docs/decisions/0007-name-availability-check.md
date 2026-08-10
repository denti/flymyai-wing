# 0007 — Name availability check for "Lidwing"

**Status:** partially resolved · **Date:** 2026-08-10 · **Escalation trigger:** T5

`DESIGN.md` §1.4 requires a USPTO, App Store, npm and GitHub search before M1 begins, and says
explicitly: report the result, do not rename on your own initiative.

## What was checked, with the command

| Registry | Command | Result |
|---|---|---|
| Mac App Store | `curl "https://itunes.apple.com/search?term=lidwing&entity=macSoftware&limit=10"` | `resultCount: 0` |
| iOS App Store | `curl "https://itunes.apple.com/search?term=lidwing&entity=software&limit=10"` | `resultCount: 0` |
| npm | `curl https://registry.npmjs.org/lidwing` | `404`; registry search returns `total: 0` |
| PyPI | `curl https://pypi.org/pypi/lidwing/json` | `404` |
| GitHub repositories | `gh api "search/repositories?q=lidwing"` | 1 result, `susembed/DS-2CV1043G2-LIDW` — a Hikvision camera document, a substring match on `LIDW`, not the name |
| DNS, `lidwing.app` | `host -t NS lidwing.app` | `NXDOMAIN` — unregistered |
| Open web | search engine, query `lidwing` | A surname (Bella Lidwing), a League of Legends summoner, and near-miss dictionary words (`lidwine`, `lacewing`). No software product, no company, no brand. |

## Not yet checked, and why

**USPTO.** The public trademark search that replaced TESS requires a browser session; its
endpoints return `404`/`405` to an unauthenticated request from this machine, and the mirrors
that would answer the question (`trademarks.justia.com`) return `403` to automated fetches.
I will not report a trademark clearance I did not actually perform.

This is deliberately left open rather than guessed at. Two acceptable ways to close it, in
order of preference:

1. Denis (or anyone with a browser) runs the search at
   <https://tmsearch.uspto.gov/> for `lidwing` in "Basic word mark search", and pastes the
   result count. Two minutes.
2. Register for a USPTO Open Data Portal API key and re-run this check from CI.

Either way, `docs/human-checklist.md` item H0 carries it.

## Assessment

Nothing found so far contests the name in the categories that matter: no software product, no
Mac or iOS app, no package on either registry a developer would search, no domain, no company.
The nearest collisions are a personal surname and a game handle, neither of which is a mark in
software or utilities.

The remaining risk is a registered word mark that only USPTO would show. That risk is bounded:
`DESIGN.md` §1.4 notes that if the name is contested, the only strings that change live in
`Constants.swift` and `Package.swift`, and nothing is shipped before M1. The cost of finding
out late rises sharply the moment a build is published, because the marker string we write into
`~/.claude/settings.json` contains the bundle path — so this must be closed **before the first
public release**, not before the first commit.

**Recommendation: proceed with `Lidwing`.** Do not rename. Close the USPTO item before the
first published build.
