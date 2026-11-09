#!/usr/bin/env perl
# cpantesters.pl - list a CPAN distribution's failing CPAN Testers reports, and
# print the full text of any of them, without the CPAN Testers web pages.
#
#   cpantesters.pl                          # dist from ./dist.ini or ./META.json, newest release
#   cpantesters.pl --dist Foo-Bar --version 1.02
#   cpantesters.pl --full                   # also print the text of every non-pass report
#   cpantesters.pl --report <guid>          # print one report's text
#   cpantesters.pl --all                    # list passes too
#
# Exit status: 0 when the listed version has no fail/unknown report, 1 when it
# has, 2 on a usage or network error.
#
# Why it exists: matrix.cpantesters.org and the www.cpantesters.org distribution
# pages answered 403 for months in 2026, while the JSON APIs behind them kept
# working. Sources, all checked by hand on 2026-11-09:
# - https://fastapi.metacpan.org/v1/release/<Dist> returns the newest indexed
#   release as JSON, with "version", "date" and "author". This, not a local
#   tarball or a commit message, is what says a version is on CPAN.
# - https://api.cpantesters.org/v3/summary/<Dist>[/<version>] returns a JSON
#   array of reports, each with guid, grade (pass, fail, na, unknown), perl,
#   osname, osvers, platform (the tester's archname), version and date. It can
#   take 20 seconds or more to answer.
# - https://api.cpantesters.org/v3/report/<guid> returns one report, with its
#   text under result.output (keys such as "uncategorized", or one per phase).
#
# Needs only core modules from perl 5.14 on. HTTP::Tiny speaks https only when
# IO::Socket::SSL and Net::SSLeay are installed, which core does not provide,
# so without them every request goes through curl instead.

use 5.014;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use HTTP::Tiny;
use JSON::PP ();
use version ();

my $USAGE = "usage: $0 [--dist Foo-Bar] [--version V] [--all] [--full] [--report GUID]\n";
my %opt;
GetOptions(\%opt, 'dist=s', 'version=s', 'all', 'full', 'report=s', 'help|h')
	or die $USAGE;
if ($opt{help}) { print $USAGE; exit 0 }

# 90 s: on 2026-11-09 the first summary request for Stats-LikeR (about 2,000
# reports) outlasted a 20 s curl timeout, and repeats answered in about 1 s.
# Four times the observed worst case leaves room for a slow day.
my $TIMEOUT = 90;
my $AGENT   = 'cpantesters.pl (cpan-release Claude Code skill)';
my $json    = JSON::PP->new->utf8;
my $http    = HTTP::Tiny->new(timeout => $TIMEOUT, agent => $AGENT);

sub get_json {
	my ($url) = @_;
	my $body;
	if ($http->can_ssl) {
		my $res = $http->get($url);
		die "GET $url: $res->{status} $res->{reason}\n" unless $res->{success};
		$body = $res->{content};
	} else {
		# The list form of open runs curl without a shell, so a dist name is
		# never interpreted as shell syntax.
		open my $fh, '-|', 'curl', '-sfL', '-m', $TIMEOUT, '-A', $AGENT, $url
			or die "cannot run curl for $url: $!\n";
		local $/;
		$body = <$fh>;
		close $fh or die "curl failed for $url (exit " . ($? >> 8) . ")\n";
	}
	return $json->decode($body);
}

sub print_report {
	my ($guid) = @_;
	my $r = get_json("https://api.cpantesters.org/v3/report/$guid");
	my $env = $r->{environment} || {};
	printf "==== %s  %s %s  perl %s  %s  (%s)\n", $guid,
		$r->{distribution}{name} // '?', $r->{distribution}{version} // '?',
		$env->{language}{version} // '?', $env->{language}{archname} // '?',
		$r->{result}{grade} // '?';
	my $out = $r->{result}{output} || {};
	for my $phase (sort keys %$out) {
		next unless defined $out->{$phase} && length $out->{$phase};
		print "---- $phase\n", $out->{$phase}, "\n";
	}
}

if ($opt{report}) {
	eval { print_report($opt{report}); 1 } or do { print STDERR $@; exit 2 };
	exit 0;
}

# The distribution's name: --dist, else the top-level name in dist.ini (Dist::Zilla),
# else "name" in META.json (any built or EUMM/MB distribution).
my $dist = $opt{dist};
if (!defined $dist && open my $fh, '<', 'dist.ini') {
	while (<$fh>) {
		if (/^\s*name\s*=\s*(\S+)/) { $dist = $1; last }
		last if /^\s*\[/;	# the first [Section] ends the top-level keys
	}
}
if (!defined $dist && open my $fh, '<', 'META.json') {
	local $/;
	$dist = eval { $json->decode(scalar <$fh>)->{name} };
}
die "cannot tell which distribution this is; pass --dist\n$USAGE" unless defined $dist;
$dist =~ s/::/-/g;

my $latest = eval { get_json("https://fastapi.metacpan.org/v1/release/$dist") };
if ($latest && $latest->{version}) {
	print "Newest on CPAN: $dist $latest->{version}, uploaded $latest->{date} by $latest->{author}\n";
} else {
	print "Newest on CPAN: none found for $dist on MetaCPAN\n";
}
my $version = $opt{version} // ($latest && $latest->{version});
die "no --version given and none found on MetaCPAN\n" unless defined $version;

my $reports = eval { get_json("https://api.cpantesters.org/v3/summary/$dist/$version") };
if (!$reports) { print STDERR $@; exit 2 }

my %count;
$count{ $_->{grade} }++ for @$reports;
printf "%s %s: %d reports (%s)\n", $dist, $version, scalar @$reports,
	join(', ', map { "$_ $count{$_}" } sort keys %count) || 'none yet';

# Sorted by grade, then perl, then platform, so the reports one cause produced
# sit together.
my @shown = sort {
	$a->{grade} cmp $b->{grade}
	|| (eval { version->parse($a->{perl}) <=> version->parse($b->{perl}) } // 0)
	|| $a->{platform} cmp $b->{platform}
} grep { $opt{all} || $_->{grade} ne 'pass' } @$reports;

for my $r (@shown) {
	printf "%-7s perl %-8s %-9s %-34s %s  %s\n",
		$r->{grade}, $r->{perl}, $r->{osname}, $r->{platform},
		substr($r->{date}, 0, 10), $r->{guid};
}
if ($opt{full}) {
	for my $r (grep { $_->{grade} ne 'pass' } @shown) {
		print "\n";
		eval { print_report($r->{guid}); 1 } or print STDERR $@;
	}
}
exit(($count{fail} || $count{unknown}) ? 1 : 0);
