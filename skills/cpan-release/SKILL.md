---
name: cpan-release
description: Triage CPAN Testers failures and prepare the next release of a Perl distribution. Use when the user pastes a CPAN Testers, smoker or magpie report; asks whether a release has failures ("check the matrix", "any bugs on cpantesters?"); or asks to bump $VERSION, write a Changes entry, or get a CPAN release ready. Covers working out what is really on CPAN, reproducing a failure on a matching perl, fixing it, verifying across every installed perl, and writing the version bump and release notes. It never uploads.
---

# CPAN release triage

The cycle this skill runs: a tester reports a failure → find which reports share
a cause → reproduce it here → fix it with a regression test → pass on every
local perl → bump `$VERSION` and write `Changes` → build, and hand the upload
to the maintainer.

**The repository's own `CLAUDE.md`, release script and test-matrix script
override anything below.** Read them first; they record conventions this skill
can only guess at.

## 1. Find out what is really on CPAN

Never infer a release from a local tarball, a `Foo-Bar-X.tar.gz` directory or a
commit named after a version. Maintainers build and commit versions they never
upload, and upload versions whose commit says nothing. Ask MetaCPAN:

```sh
perl <this skill's directory>/scripts/cpantesters.pl          # run from the dist root
```

Its first line names the newest version on CPAN. Compare it with `$VERSION` in
the main module and with the newest heading in `Changes`:

| `$VERSION` vs newest on CPAN | meaning |
|---|---|
| equal | that version shipped; its `Changes` section is closed, and new work needs a new version |
| greater | that version is in progress; new work goes under its existing section |
| less | something is wrong: stop and ask |

A version uploaded in the last hour may not be indexed yet. If the maintainer
says they uploaded it, believe them over the API.

## 2. Collect and group the failures

When the user pasted a report, start from it. Otherwise:

```sh
perl <skill dir>/scripts/cpantesters.pl                     # non-pass reports for the newest release
perl <skill dir>/scripts/cpantesters.pl --version 1.02 --full
perl <skill dir>/scripts/cpantesters.pl --report <guid>     # one report's full text
```

These use the JSON APIs, which kept working while the CPAN Testers web pages
returned 403. Exit status 1 means fail or unknown reports exist.

For each failing report, record the perl version, `osname` and archname, and
read the archname's tokens: `thread`/`multi` (ithreads), `64int` (64-bit IV on a
32-bit CPU), `ld` (long-double NV), `quadmath` (`__float128` NV), `i686`/`i386`
(32-bit), `MSWin32`/`cygwin`/`freebsd`/`openbsd`/`solaris`. Then group the
reports by cause. Ten reports often share one cause, and one report can hold
two.

Sort each cause into one of three kinds before touching code:

- **Module bug.** The module gives the wrong answer on that platform.
- **Test bug.** The module was right, but the test assumed something the
  platform does not give, such as text-mode line endings, a path separator, IV
  width, hash order or locale.
- **Tester's environment.** A missing prerequisite, a broken toolchain, a full
  disk, or an `na` grade for an unsupported perl. These need no release. Say so,
  and name the tester if they should be told.

## 3. Reproduce it before fixing it

Find a local perl with the same failing axis (`perlbrew list`, or the perls the
repository's matrix script names). Run the failing test file on that perl alone,
and watch it fail the same way the report does.

When no local perl has the axis, emulate it if you can. For example,
`PERLIO=:unix:crlf` reproduces Windows text-mode line endings on Linux. When you
can't, say which perl would reproduce it (for example `perlbrew install
perl-5.44.0 -Duse64bitint` on an i686 build) and ask before building one, since a
build takes a long time.

If a failure can't be reproduced, report it as not reproduced, along with your
best reading of the report. Never present a guessed fix as a confirmed one.

## 4. Fix the cause and add a regression test

- Write a test that fails on the unfixed code, and confirm that it does.
- Fix the cause, not the symptom. Never loosen a tolerance, add a `skip` or mark
  a test TODO just to turn a report green. When a skip is the right answer
  because the platform really lacks the feature, write the reason in a comment
  beside it.
- Fix the same mistake everywhere it occurs, not only at the line the report
  names. Search the module and the tests for the same pattern.

## 5. Verify on every local perl

Run the repository's matrix script if it has one (such as `test.all.perls.pl`).
Otherwise loop over `perlbrew list`.

- A full matrix can take longer than the foreground tool limit. Start it **once**
  with `run_in_background`, then wait with a foreground
  `while kill -0 PID; do sleep 30; done`. Don't use `pgrep -f` or `pkill -f`: the
  pattern matches your own shell.
- Never run `make`, `make test` or `prove` while the matrix is running. Builds
  that share one tree overwrite each other's object files. A collision looks like
  a catastrophic regression: every function fails, often with nonsense numbers,
  and the run is suspiciously fast.
- Read results from each perl's own log rather than a summary line.
- Afterwards, rebuild the root for the default perl (`make clean && perl
  Makefile.PL && make`). After a `$VERSION` change, XS needs `perl Makefile.PL`
  again, because the Makefile bakes `XS_VERSION` in.

## 6. Bump `$VERSION` and write `Changes`

- **Use the version number the maintainer gives.** If they haven't given one,
  propose the next version from the repository's own history (`git log
  --oneline`, the `Changes` headings) and wait for agreement. Schemes differ:
  some go 0.33 → 0.331 → 0.3311, others 0.03 → 0.04. Do not assume either.
- Change every place the version lives: the main module, any submodule whose
  version a test requires to match, `dist.ini` if it states one, and the README
  if it quotes one.
- Prepend a section to `Changes` that copies the existing format exactly: the
  heading line (version, date, time zone, and any credit note the repository
  uses), bracketed group headings, indentation and wrap width. Each entry says
  what changed, why, and which reports or platforms showed it. Name the test
  files and the subtest count, and say whether the module or the test was at
  fault.
- Never reword a section that has shipped.
- Check the file still parses the way PAUSE will parse it:
  `perl -MCPAN::Changes -e 'CPAN::Changes->load("Changes")'`.
- If a hook or `CLAUDE.md` forbids editing `Changes`, put the proposed entry in
  your reply instead.

## 7. Build, then stop

- Read the release script (`dzil.sh`, `release.sh`, a `Makefile` target) before
  running it. **If it uploads (`dzil release`, `cpan-upload`), do not run it.**
  Give the maintainer the command. PAUSE never accepts the same file name twice,
  so a bad upload can only be fixed by releasing another version.
- After a build, list the tarball. Check that new test files are inside it
  (`[Git::GatherDir]` ships only files git tracks) and that no build products
  are: `blib/`, `*.o`, `*.so`, `*.c` generated from XS, `Makefile`, `MYMETA.*`,
  `cover_db/` or `*.orig`.
- Never commit, tag or push unless asked, or unless the repository's release
  script does it as its documented job.

## 8. Close the loop

When a failure came from a class of mistake rather than a one-off (for example
"fixtures must be opened binary", or "a `size_t` is narrower than an IV on 32-bit
perls"), propose a short rule for the repository's `CLAUDE.md` that would have
prevented it. Add the rule if the maintainer agrees.

## Report back

End with a table of each cause, the reports it covers, its kind, whether you
reproduced it and on which perl, and its status. Below the table, give the
version and `Changes` entry you wrote or propose, and the exact command the
maintainer runs to upload.
