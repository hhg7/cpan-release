#!/usr/bin/env perl
# cpantesters.pl - list a CPAN distribution's failing reports from CPAN Testers
# and from CPAN Testers Magpie, and print the full text of any of them, without
# the CPAN Testers web pages.
#
#   cpantesters.pl                          # dist from ./dist.ini or ./META.json, newest release
#   cpantesters.pl --dist Foo-Bar --version 1.02
#   cpantesters.pl --full                   # also print the text of every non-pass report
#   cpantesters.pl --report <guid>          # print one report's text
#   cpantesters.pl --all                    # list passes too
#   cpantesters.pl --no-magpie              # ask CPAN Testers only
#
# Exit status: 0 when the listed version has no fail/unknown report in either
# source, 1 when it has, 2 on a usage error or when no source answered.
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
# Magpie (https://magpie.cpantesters.org, linked from the CPAN Testers home
# page as a second aggregation of the same reports) is asked as well, because
# either service can be down or behind the other. Its JSON was read by hand on
# 2026-11-09; it is the HTML page's own data, selected by ?json=1:
# - /dist/<Dist>/<version>/?json=1 has "grade_count" (PASS, FAIL, NA, UNKNOWN)
#   over every report of that version.
# - /dist/<Dist>/<version>/<GRADE>/?json=1 has, under "results", the reports of
#   that grade: guid, grade, perl_version ("v5.42.3"), osname (a family such as
#   "windows" or "bsd"), arch_name (the archname) and unixtime. "result_count"
#   there is still the whole version's count, so count "results" instead.
# - /results/<guid>?json=1 has one report, its text under info.text_report.
# - An unknown distribution or version answers 200 with an HTML error page,
#   which fails to decode as JSON and is reported as Magpie not answering.
# A guid is the same report in both services, so the two lists are compared by
# guid and a report only one of them holds is marked.
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

my $USAGE = "usage: $0 [--dist Foo-Bar] [--version V] [--all] [--full] [--report GUID] [--no-magpie]\n";
my %opt = (magpie => 1);
GetOptions(\%opt, 'dist=s', 'version=s', 'all', 'full', 'report=s', 'magpie!', 'help|h')
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

my $MAGPIE = 'https://magpie.cpantesters.org';

# One report's text from Magpie, for a report CPAN Testers' API does not hold
# or cannot serve.
sub print_magpie_report {
	my ($guid) = @_;
	my $i = get_json("$MAGPIE/results/$guid?json=1")->{info} || {};
	printf "==== %s  %s %s  perl %s  %s  (%s, from Magpie)\n", $guid,
		$i->{distribution_name} // '?', $i->{distribution_version} // '?',
		$i->{perl_version} // '?', $i->{arch_name} // '?', lc($i->{grade} // '?');
	print $i->{text_report} // "(Magpie holds no text for this report)\n", "\n";
}

sub print_report {
	my ($guid) = @_;
	# A guid goes into a URL, so it must look like one.
	die "not a report guid: $guid\n" unless $guid =~ /\A[0-9a-fA-F-]{8,64}\z/;
	my $r = eval { get_json("https://api.cpantesters.org/v3/report/$guid") };
	if (!$r) {
		my $err = $@;
		die $err unless $opt{magpie};
		print STDERR "CPAN Testers: $err" . "trying Magpie for $guid\n";
		return print_magpie_report($guid);
	}
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
my $ct_ok   = $reports ? 1 : 0;	# whether CPAN Testers answered at all
if (!$ct_ok) {
	print STDERR "CPAN Testers did not answer: $@";
	exit 2 unless $opt{magpie};
	$reports = [];
}

my %count;
$count{ $_->{grade} }++ for @$reports;
printf "%s %s: %d reports (%s)\n", $dist, $version, scalar @$reports,
	join(', ', map { "$_ $count{$_}" } sort keys %count) || 'none yet' if $ct_ok;

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

# Magpie's view of the same version. Every non-pass grade it counts is listed,
# and each report is marked when CPAN Testers' list above lacks its guid.
my (%mcount, @mshown, $magpie_ok);
if ($opt{magpie}) {
	$magpie_ok = eval {
		my $sum = get_json("$MAGPIE/dist/$dist/$version/?json=1");
		%mcount = map { lc($_) => $sum->{grade_count}{$_} } grep { $sum->{grade_count}{$_} }
			keys %{ $sum->{grade_count} || {} };
		for my $grade (sort grep { $opt{all} || $_ ne 'pass' } keys %mcount) {
			my $list = get_json("$MAGPIE/dist/$dist/$version/" . uc($grade) . "/?json=1")->{results};
			push @mshown, @{ ref $list eq 'ARRAY' ? $list : [] };
		}
		1;
	};
	if ($magpie_ok) {
		my $total = 0;
		$total += $_ for values %mcount;
		printf "Magpie %s %s: %d reports (%s)\n", $dist, $version, $total,
			join(', ', map { "$_ $mcount{$_}" } sort keys %mcount) || 'none yet';
		my %in_ct = map { $_->{guid} => 1 } @$reports;
		# The same order as the list above: grade, then perl, then platform.
		@mshown = sort {
			lc($a->{grade} // '') cmp lc($b->{grade} // '')
			|| (eval { version->parse($a->{perl_version}) <=> version->parse($b->{perl_version}) } // 0)
			|| ($a->{arch_name} // '') cmp ($b->{arch_name} // '')
		} @mshown;
		for my $r (@mshown) {
			my @t = gmtime($r->{unixtime} // 0);
			(my $perl = $r->{perl_version} // '?') =~ s/^v//;
			printf "%-7s perl %-8s %-9s %-34s %04d-%02d-%02d  %s%s\n",
				lc($r->{grade} // '?'), $perl, $r->{osname} // '?', $r->{arch_name} // '?',
				$t[5] + 1900, $t[4] + 1, $t[3], $r->{guid} // '?',
				($ct_ok && !$in_ct{ $r->{guid} // '' }) ? '  [Magpie only]' : '';
		}
		# The other direction: a non-pass report CPAN Testers has and Magpie lacks.
		my %in_magpie = map { ($_->{guid} // '') => 1 } @mshown;
		for my $r (grep { $_->{grade} ne 'pass' && !$in_magpie{ $_->{guid} } } @$reports) {
			print "note: $r->{grade} report $r->{guid} is on CPAN Testers and not on Magpie\n";
		}
	} else {
		print STDERR "Magpie did not answer: $@";
		exit 2 unless $ct_ok;
	}
}

if ($opt{full}) {
	my %seen;
	for my $guid (grep { !$seen{$_}++ }
			(map { $_->{guid} } grep { $_->{grade} ne 'pass' } @shown),
			(map { $_->{guid} } grep { defined $_->{guid} && lc($_->{grade} // '') ne 'pass' } @mshown)) {
		print "\n";
		eval { print_report($guid); 1 } or print STDERR $@;
	}
}
exit(($count{fail} || $count{unknown} || $mcount{fail} || $mcount{unknown}) ? 1 : 0);
