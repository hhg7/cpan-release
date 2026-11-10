# cpan-release

A Claude Code plugin for CPAN authors. Its one skill, `cpan-release`, takes a
failing CPAN Testers report (or just "check the matrix") and runs the whole
cycle:

1. Ask MetaCPAN what is really released, instead of guessing from local
   tarballs or commit messages.
2. Groups the failing reports by cause, and separates module bugs from test
   bugs and from problems in the tester's own environment.
3. Reproduces each failure on a local perl with the same build options
   (threads, 64-bit IV, long double, quadmath, 32-bit), or emulates it.
4. Fixes the cause and adds a regression test that fails without the fix.
5. Verifies the fix on every installed perl.
6. Bumps `$VERSION` and writes the `Changes` entry in the distribution's own
   format.
7. Builds and checks the tarball, then stops. **It never uploads to PAUSE.**

It comes with `scripts/cpantesters.pl`, which lists a release's failing reports
and prints their full text from the CPAN Testers JSON API. That API kept working
while the CPAN Testers web pages returned 403. The script needs only core
modules from perl 5.14 on, and it uses `curl` when `IO::Socket::SSL` is not
installed.

## Install

Once the repository is on GitHub, run this inside Claude Code:

```
/plugin install cpan-release --marketplace hhg7/cpan-release
```

To use it from a local checkout, link the skill into your personal skills
directory:

```sh
ln -s ~/Scripts/cpan-release/skills/cpan-release ~/.claude/skills/cpan-release
```

## Use

From the root of a distribution, you can say any of these:

- "a magpie tester failed:" followed by the pasted report
- "are there any failures for the latest release?"
- "bump `$VERSION` to 0.3419 and update `Changes`"

Your repository's `CLAUDE.md` and release script take precedence over the
skill's defaults.
