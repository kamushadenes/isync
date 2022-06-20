#! /usr/bin/perl -w
#
# SPDX-FileCopyrightText: 2006-2022 Oswald Buddenhagen <ossi@users.sf.net>
# SPDX-License-Identifier: GPL-2.0-or-later
#

use warnings;
use strict;

use Carp;
$SIG{__WARN__} = \&Carp::cluck;
$SIG{__DIE__} = \&Carp::confess;

use Cwd;
use Clone 'clone';
use File::Path;
use File::Temp 'tempdir';

my $use_vg = $ENV{USE_VALGRIND};
my $use_st = $ENV{USE_STRACE};
my $mbsync = getcwd()."/mbsync";

my (@match, $start);
for my $arg (@ARGV) {
	if ($arg eq "+") {
		$start = 1;
	} else {
		push @match, $arg;
	}
}
die("Need exactly one test name when using start syntax.\n")
	if ($start && (@match != 1));

if (!-d "tmp") {
  unlink "tmp";
  my $tdir = tempdir();
  symlink $tdir, "tmp" or die "Cannot symlink temp directory: $!\n";
}
chdir "tmp" or die "Cannot enter temp direcory.\n";

use enum qw(:=1 A..Z);
use enum qw(:A=27 A..Z);
sub mn($) { my $n = shift; $n == 0 ? "0" : $n > 26 ? "A".chr(64 - 26 + $n) : chr(64 + $n) }
sub mf($) { my ($f) = @_; length($f) ? $f : '-' }

my $sync_flags = "<>^~DFPRST";
my $msg_flags = "DFPRST*?";

sub process_flag_add($$$$$$)
{
	my ($flgr, $add, $ok_flags, $num, $e, $what) = @_;

	return if ($add eq "");
	for my $flg (split('', $add)) {
		die("Adding invalid flag '$flg' for $what ".mn($num)." (at $e).\n")
			if (index($ok_flags, $flg) < 0);
		my $i = index($$flgr, $flg);
		die("Adding duplicate flag '$flg' to $what ".mn($num)." (at $e).\n")
			if ($i >= 0);
		$$flgr .= $flg;
	}
	$$flgr = $ok_flags =~ s/[^$$flgr]//gr;  # sort
}

sub process_flag_del($$$$$)
{
	my ($flgr, $del, $num, $e, $what) = @_;

	for my $flg (split('', $del)) {
		my $i = index($$flgr, $flg);
		die("Removing absent flag '$flg' from $what ".mn($num)." (at $e).\n")
			if ($i < 0);
		substr($$flgr, $i, 1) = '';
	}
}

sub process_flag_update($$$$$$$)
{
	my ($flgr, $add, $del, $ok_flags, $num, $e, $what) = @_;

	process_flag_del($flgr, $del, $num, $e, $what);
	process_flag_add($flgr, $add, $ok_flags, $num, $e, $what);
}

sub parse_flags($$$$$)
{
	my ($rflg, $ok_flags, $num, $e, $what) = @_;

	my $add = $$rflg;
	$$rflg = "";
	process_flag_add($rflg, $add, $ok_flags, $num, $e, $what);
}

sub parse_flag_update($)
{
	my ($stsr) = @_;

	my ($add, $del) = ("", "");
	while ($$stsr =~ s,^([-+])([^-+]+),,) {
		if ($1 eq "+") {
			$add .= $2;
		} else {
			$del .= $2;
		}
	}
	return ($add, $del);
}

# Returns UID.
sub create_msg($$$$$)
{
	my ($num, $flg, $bs, $t, $e) = @_;

	my ($mur, $msr, $n2ur) = (\$$bs{max_uid}, $$bs{messages}, $$bs{num2uid});
	$$mur++;
	if ($flg ne "_") {
		parse_flags(\$flg, $msg_flags, $num, $e, "$t side");
		$$msr{$$mur} = [ $num, $flg ];
	}
	push @{$$n2ur{$num}}, $$mur;
	return $$mur;
}

# Returns old UID, new UID.
sub parse_msg($$$$$)
{
	my ($num, $sts, $cs, $t, $e) = @_;

	my $bs = $$cs{$t};
	my ($msr, $n2ur) = ($$bs{messages}, $$bs{num2uid});

	$$cs{"${t}_trash"}{$num} = 1
		if ($sts =~ s,^#,,);
	my $ouid;
	my $uids = \@{$$n2ur{$num}};
	if ($sts =~ s,^&$,,) {
		$ouid = 0;
	} elsif ($sts =~ s,^&(\d+),,) {
		my $n = int($1);
		die("Referencing unrecognized instance $n of message ".mn($num)." on $t side (at $e).\n")
			if (!$n || $n > @$uids);
		$ouid = $$uids[$n - 1];
	} else {
		$ouid = @$uids ? $$uids[-1] : 0;
	}
	my $nuid = ($sts =~ s,^\|,,) ? 0 : $ouid;
	if ($sts eq "_" or $sts =~ s,^\*,,) {
		die("Adding already present message ".mn($num)." on $t side (at $e).\n")
			if (defined($$msr{$ouid}));
		$nuid = create_msg($num, $sts, $bs, $t, $e);
	} elsif ($sts =~ s,^\^,,) {
		die("Duplicating absent message ".mn($num)." on $t side (at $e).\n")
			if (!defined($$msr{$ouid}));
		$nuid = create_msg($num, $sts, $bs, $t, $e);
	} elsif ($sts eq "/") {
		# Note that we don't delete $$n2ur{$num}, as state entries may
		# refer to expunged messages. Subject re-use is not supported here.
		die("Deleting absent message ".mn($num)." from $t side (at $e).\n")
			if (!delete $$msr{$ouid});
		$nuid = 0;
	} elsif ($sts ne "") {
		my ($add, $del) = parse_flag_update(\$sts);
		die("Unrecognized message command '$sts' for $t side (at $e).\n")
			if ($sts ne "");
		die("No message ".mn($num)." present on $t side (at $e).\n")
			if (!defined($$msr{$ouid}));
		process_flag_update(\$$msr{$ouid}[1], $add, $del, $msg_flags, $num, $e, "$t side");
	}
	return $ouid, $nuid;
}

# Returns UID.
sub resolv_msg($$$)
{
	my ($num, $cs, $t) = @_;

	return 0 if (!$num);
	my $uids = \@{$$cs{$t}{num2uid}{$num}};
	die("No message ".mn($num)." present on $t side (in header).\n")
		if (!@$uids);
	return $$uids[-1];
}

# Returns index, or undef if not found.
sub find_ent($$$)
{
	my ($fu, $nu, $ents) = @_;

	for (my $i = 0; $i < @$ents; $i++) {
		my $ent = $$ents[$i];
		return $i if ($$ent[0] == $fu and $$ent[1] == $nu);
	}
	return undef;
}

sub find_ent_chk($$$$$)
{
	my ($fu, $nu, $cs, $num, $e) = @_;

	my $enti = find_ent($fu, $nu, $$cs{state}{entries});
	die("No state entry $fu:$nu present for ".mn($num)." (at $e).\n")
		if (!defined($enti));
	return $enti;
}

sub parse_chan($;$)
{
	my ($ics, $ref) = @_;

	my $cs;
	if ($ref) {
		$cs = clone($ref);
	} else {
		$cs = {
			# messages: { uid => [ subject, flags ], ... }
			far => { max_uid => 0, messages => {}, num2uid => {} },
			near => { max_uid => 0, messages => {}, num2uid => {} },
			# trashed messages: { subject => is_placeholder, ... }
			far_trash => { },
			near_trash => { },
			# entries: [ [ far_uid, near_uid, flags ], ... ]
			state => { entries => [] }
		};
	}

	my $ss = $$cs{state};
	my $ents = $$ss{entries};
	my $enti;
	for (my ($i, $e) = (3, 1); $i < @$ics; $i += 4, $e++) {
		my ($num, $far, $sts, $near) = @{$ics}[$i .. $i+3];
		my ($ofu, $nfu) = parse_msg($num, $far, $cs, "far", $e);
		my ($onu, $nnu) = parse_msg($num, $near, $cs, "near", $e);
		if ($sts =~ s,^\*,,) {
			$enti = find_ent($nfu, $nnu, $ents);
			die("State entry $nfu:$nnu already present for ".mn($num)." (at $e).\n")
				if (defined($enti));
			parse_flags(\$sts, $sync_flags, $num, $e, "sync entry");
			push @$ents, [ $nfu, $nnu, $sts ];
		} elsif ($sts =~ s,^\^,,) {
			die("No current state entry for ".mn($num)." (at $e).\n")
				if (!defined($enti));
			parse_flags(\$sts, $sync_flags, $num, $e, "sync entry");
			splice @$ents, $enti++, 0, ([ $nfu, $nnu, $sts ]);
		} elsif ($sts eq "/") {
			$enti = find_ent_chk($ofu, $onu, $cs, $num, $e);
			splice @$ents, $enti, 1;
		} elsif ($sts ne "") {
			my $t = -1;
			if ($sts =~ s,^<,,) {
				$t = 0;
			} elsif ($sts =~ s,^>,,) {
				$t = 1;
			}
			my ($add, $del) = parse_flag_update(\$sts);
			die("Unrecognized state command '".$sts."' for ".mn($num)." (at $e).\n")
				if ($sts ne "");
			$enti = find_ent_chk($ofu, $onu, $cs, $num, $e);
			my $ent = $$ents[$enti++];
			process_flag_update(\$$ent[2], $add, $del, $sync_flags, $num, $e, "sync entry");
			if ($t >= 0) {
				my $uid = $t ? $nnu : $nfu;
				$$ent[$t] = ($uid && $$cs{$t ? "near" : "far"}{messages}{$uid}) ? $uid : 0;
			}
		} else {
			$enti = undef;
		}
	}

	$$ss{max_pulled} = resolv_msg($$ics[0], $cs, "far");
	$$ss{max_expired_far} = resolv_msg($$ics[1], $cs, "far");
	$$ss{max_pushed} = resolv_msg($$ics[2], $cs, "near");
	$$ss{max_expired_near} = 0;

	return $cs;
}

sub flip_chan($)
{
	my ($cs) = @_;

	($$cs{far}, $$cs{near}) = ($$cs{near}, $$cs{far});
	($$cs{far_trash}, $$cs{near_trash}) = ($$cs{near_trash}, $$cs{far_trash});
	my $ss = $$cs{state};
	($$ss{max_pulled}, $$ss{max_pushed}) = ($$ss{max_pushed}, $$ss{max_pulled});
	($$ss{max_expired_far}, $$ss{max_expired_near}) = ($$ss{max_expired_near}, $$ss{max_expired_far});
	for my $ent (@{$$ss{entries}}) {
		($$ent[0], $$ent[1]) = ($$ent[1], $$ent[0]);
		$$ent[2] =~ tr/<>/></;
	}
}


sub qm($)
{
	shift;
	s/\\/\\\\/g;
	s/\"/\\"/g;
	s/\"/\\"/g;
	s/\n/\\n/g;
	return $_;
}

# [ $far, $near, $channel ]
sub writecfg($)
{
	my ($sfx) = @_;

	open(FILE, ">", ".mbsyncrc") or
		die "Cannot open .mbsyncrc.\n";
	print FILE
"FSync no

MaildirStore far
Path \"\"
Inbox far
".$$sfx[0]."
MaildirStore near
Path \"\"
Inbox near
".$$sfx[1]."
Channel test
Far :far:
Near :near:
SyncState *
".$$sfx[2];
	close FILE;
}

sub killcfg()
{
	unlink $_ for (glob("*.log"));
	unlink ".mbsyncrc";
}

# $run_async, $mbsync_options, $log_file
# Return: $exit_code, \@mbsync_output
sub runsync($$$)
{
	my ($async, $flags, $file) = @_;

	my $cmd;
	if ($use_vg) {
		$cmd = "valgrind -q --error-exitcode=1 ";
	} elsif ($use_st) {
		$cmd = "strace ";
	} else {
		$flags .= " -D";
	}
	if ($async == 2) {
		$flags .= " -TA";
	} elsif ($async == 1) {
		$flags .= " -Ta";
	}
	$cmd .= "$mbsync -Tz $flags -c .mbsyncrc test";
	open FILE, "$cmd 2>&1 |";
	my @out = <FILE>;
	close FILE or push(@out, $! ? "*** error closing mbsync: $!\n" : "*** mbsync exited with signal ".($?&127).", code ".($?>>8)."\n");
	if ($file) {
		open FILE, ">$file" or die("Cannot create $file: $!\n");
		print FILE @out;
		close FILE;
	}
	return $?, \@out;
}


use constant CHOMP => 1;

sub readfile($;$)
{
	my ($file, $chomp) = @_;

	open(FILE, $file) or return;
	my @nj = <FILE>;
	close FILE;
	chomp(@nj) if ($chomp);
	return \@nj;
}

# $path
sub readbox_impl($$)
{
	my ($bn, $cb) = @_;

	(-d $bn."/tmp" and -d $bn."/new" and -d $bn."/cur") or
		die "Invalid mailbox '$bn'.\n";
	for my $d ("cur", "new") {
		opendir(DIR, $bn."/".$d) or next;
		for my $f (grep(!/^\.\.?$/, readdir(DIR))) {
			open(FILE, "<", $bn."/".$d."/".$f) or die "Cannot read message '$f' in '$bn'.\n";
			my ($sz, $num, $ph) = (0);
			while (<FILE>) {
				/^Subject: (\[placeholder\] )?(\d+)$/ && ($ph = defined($1), $num = int($2));
				$sz += length($_);
			}
			close FILE;
			if (!defined($num)) {
				print STDERR "message '$f' in '$bn' has no identifier.\n";
				exit 1;
			}
			$cb->($num, $ph, $sz, $f);
		}
	}
}

# $path
sub readbox($)
{
	my $bn = shift;

	(-d $bn) or
		die "No mailbox '$bn'.\n";
	my %ms;
	readbox_impl($bn, sub {
		my ($num, $ph, $sz, $f) = @_;
		if ($f !~ /^\d+\.\d+_\d+\.[-[:alnum:]]+,U=(\d+):2,(.*)$/) {
			print STDERR "unrecognided file name '$f' in '$bn'.\n";
			exit 1;
		}
		my ($uid, $flg) = (int($1), $2);
		@{$ms{$uid}} = ($num, $flg.($sz > 1000 ? "*" : "").($ph ? "?" : ""));
	});
	my $uidval = readfile($bn."/.uidvalidity", CHOMP);
	die "Cannot read UID validity of mailbox '$bn': $!\n" if (!$uidval);
	my $mu = $$uidval[1];
	return { max_uid => $mu, messages => \%ms };
}

# $path
sub readtrash($)
{
	my $bn = shift;

	(-d $bn) or
		return {};
	my %ms;
	readbox_impl($bn, sub {
		my ($num, $ph, undef, undef) = @_;
		$ms{$num} = $ph;
	});
	return \%ms;
}

# \%fallback_sync_state
sub readstate(;$)
{
	my ($fbss) = @_;

	my $fn = "near/.mbsyncstate";
	if ($fbss) {
		$fn .= ".new";
		return $fbss if (!-s $fn);
	}
	my $ls = readfile($fn, CHOMP);
	if (!$ls) {
		print STDERR "Cannot read sync state $fn: $!\n";
		return;
	}
	my @ents;
	my %ss = (
		max_pulled => 0,
		max_expired_far => 0,
		max_pushed => 0,
		max_expired_near => 0,
		entries => \@ents
	);
	my ($far_val, $near_val) = (0, 0);
	my %hdr = (
		'FarUidValidity' => \$far_val,
		'NearUidValidity' => \$near_val,
		'MaxPulledUid' => \$ss{max_pulled},
		'MaxPushedUid' => \$ss{max_pushed},
		'MaxExpiredFarUid' => \$ss{max_expired_far},
		'MaxExpiredNearUid' => \$ss{max_expired_near}
	);
	OUTER: while (1) {
		while (@$ls) {
			$_ = shift(@$ls);
			last OUTER if (!length($_));
			if (!/^([^ ]+) (\d+)$/) {
				print STDERR "Malformed sync state header entry: $_\n";
				return;
			}
			my $want = delete $hdr{$1};
			if (!defined($want)) {
				print STDERR "Unexpected sync state header entry: $1\n";
				return;
			}
			$$want = int($2);
		}
		print STDERR "Unterminated sync state header.\n";
		return;
	}
	delete $hdr{'MaxExpiredFarUid'};  # optional field
	delete $hdr{'MaxExpiredNearUid'};  # ditto
	my @ky = keys %hdr;
	if (@ky) {
		print STDERR "Keys missing from sync state header: @ky\n";
		return;
	}
	if ($far_val ne '1' or $near_val ne '1') {
		print STDERR "Unexpected UID validity $far_val $near_val (instead of 1 1)\n";
		return;
	}
	for (@$ls) {
		if (!/^(\d+) (\d+) (.*)$/) {
			print STDERR "Malformed sync state entry: $_\n";
			return;
		}
		push @ents, [ int($1), int($2), $3 ];
	}
	return \%ss;
}

# \%fallback_sync_state
sub readchan(;$)
{
	my ($fbss) = @_;

	return {
		far => readbox("far"),
		near => readbox("near"),
		far_trash => readtrash("far_trash"),
		near_trash => readtrash("near_trash"),
		state => readstate($fbss)
	};
}

# $box_name, \%box_state
sub mkbox($$)
{
	my ($bn, $bs) = @_;

	rmtree($bn);
	(mkdir($bn) and mkdir($bn."/tmp") and mkdir($bn."/new") and mkdir($bn."/cur")) or
		die "Cannot create mailbox $bn.\n";
	open(FILE, ">", $bn."/.uidvalidity") or die "Cannot create UID validity for mailbox $bn.\n";
	print FILE "1\n$$bs{max_uid}\n";
	close FILE;
	my $ms = $$bs{messages};
	for my $uid (keys %$ms) {
		my ($num, $flg) = @{$$ms{$uid}};
		my $big = $flg =~ s/\*//;
		my $ph = $flg =~ s/\?//;
		open(FILE, ">", $bn."/".($flg =~ /S/ ? "cur" : "new")."/0.1_".$num.".local,U=".$uid.":2,".$flg) or
			die "Cannot create message ".mn($num)." in mailbox $bn.\n";
		print FILE "From: foo\nTo: bar\nDate: Thu, 1 Jan 1970 00:00:00 +0000\nSubject: ".($ph?"[placeholder] ":"").$num."\n\n".(("A"x50)."\n")x($big*30);
		close FILE;
	}
}

# \%sync_state
sub mkstate($)
{
	my ($ss) = @_;

	open(FILE, ">", "near/.mbsyncstate") or
		die "Cannot create sync state.\n";
	print FILE "FarUidValidity 1\nMaxPulledUid ".$$ss{max_pulled}."\n".
	           "NearUidValidity 1\nMaxPushedUid ".$$ss{max_pushed}."\n";
	print FILE "MaxExpiredFarUid ".$$ss{max_expired_far}."\n"
		if ($$ss{max_expired_far});
	print FILE "MaxExpiredNearUid ".$$ss{max_expired_near}."\n"
		if ($$ss{max_expired_near});
	print FILE "\n";
	for my $ent (@{$$ss{entries}}) {
		print FILE $$ent[0]." ".$$ent[1]." ".$$ent[2]."\n";
	}
	close FILE;
}

# \%chan_state
sub mkchan($)
{
	my ($cs) = @_;

	mkbox("far", $$cs{far});
	mkbox("near", $$cs{near});
	rmtree("far_trash");
	rmtree("near_trash");
	mkstate($$cs{state});
}

# $box_name, \%actual_box_state, \%reference_box_state
sub cmpbox($$$)
{
	my ($bn, $bs, $ref_bs) = @_;

	my $ret = 0;
	my ($ref_mu, $ref_ms) = ($$ref_bs{max_uid}, $$ref_bs{messages});
	my ($mu, $ms) = ($$bs{max_uid}, $$bs{messages});
	if ($mu != $ref_mu) {
		print STDERR "MAXUID mismatch for '$bn': got $mu, wanted $ref_mu\n";
		$ret = 1;
	}
	for my $uid (sort { $a <=> $b } keys %$ref_ms) {
		my ($num, $flg) = @{$$ref_ms{$uid}};
		my $m = $$ms{$uid};
		if (!defined $m) {
			print STDERR "Missing message $bn:$uid:".mn($num)."\n";
			$ret = 1;
			next;
		}
		if ($$m[0] != $num) {
			print STDERR "Subject mismatch for $bn:$uid:".
					" got ".mn($$m[0]).", wanted ".mn($num)."\n";
			return 1;
		}
		if ($$m[1] ne $flg) {
			print STDERR "Flag mismatch for $bn:$uid:".mn($num).":".
					" got ".mf($$m[1]).", wanted ".mf($flg)."\n";
			$ret = 1;
		}
	}
	for my $uid (sort { $a <=> $b } keys %$ms) {
		if (!defined($$ref_ms{$uid})) {
			print STDERR "Excess message $bn:$uid:".mn($$ms{$uid}[0])."\n";
			$ret = 1;
		}
	}
	return $ret;
}

# $box_name, \%actual_box_state, \%reference_box_state
sub cmptrash($$$)
{
	my ($bn, $ms, $ref_ms) = @_;

	my $ret = 0;
	for my $num (sort { $a <=> $b } keys %$ref_ms) {
		my $ph = $$ms{$num};
		if (!defined($ph)) {
			print STDERR "Missing message $bn:".mn($num)."\n";
			$ret = 1;
		}
		if ($ph) {
			print STDERR "Message $bn:".mn($num)." is placeholder\n";
			$ret = 1;
		}
	}
	for my $num (sort { $a <=> $b } keys %$ms) {
		if (!defined($$ref_ms{$num})) {
			print STDERR "Excess message $bn:".mn($num).($$ms{$num} ? " (is placeholder)" : "")."\n";
			$ret = 1;
		}
	}
	return $ret;
}

sub mapmsg($$)
{
	my ($uid, $bs) = @_;

	if ($uid) {
		if (my $msg = $$bs{messages}{$uid}) {
			return $$msg[0];
		}
	}
	return 0;
}

# \%actual_chan_state, \%reference_chan_state
sub cmpstate($$)
{
	my ($cs, $ref_cs) = @_;

	my ($ss, $fbs, $nbs) = ($$cs{state}, $$cs{far}, $$cs{near});
	return 1 if (!$ss);
	my ($ref_ss, $ref_fbs, $ref_nbs) = ($$ref_cs{state}, $$ref_cs{far}, $$ref_cs{near});
	return 0 if ($ss == $ref_ss);
	my $ret = 0;
	for my $h (['MaxPulledUid', 'max_pulled'],
	           ['MaxExpiredFarUid', 'max_expired_far'],
	           ['MaxPushedUid', 'max_pushed'],
	           ['MaxExpiredNearUid', 'max_expired_near']) {
		my ($hn, $sn) = @$h;
		my ($got, $want) = ($$ss{$sn}, $$ref_ss{$sn});
		if ($got != $want) {
			print STDERR "Sync state header entry $hn mismatch: got $got, wanted $want\n";
			$ret = 1;
		}
	}
	my $ref_ents = $$ref_ss{entries};
	my $ents = $$ss{entries};
	for (my $i = 0; $i < @$ents || $i < @$ref_ents; $i++) {
		my ($ent, $fuid, $nuid, $num);
		if ($i < @$ents) {
			$ent = $$ents[$i];
			($fuid, $nuid) = ($$ent[0], $$ent[1]);
			my ($fnum, $nnum) = (mapmsg($fuid, $fbs), mapmsg($nuid, $nbs));
			if ($fnum && $nnum && $fnum != $nnum) {
				print STDERR "Invalid sync state entry $fuid:$nuid:".
						" mismatched subjects (".mn($fnum).":".mn($nnum).")\n";
				return 1;
			}
			$num = $fnum || $nnum;
		}
		if ($i == @$ref_ents) {
			print STDERR "Excess sync state entry $fuid:$nuid (".mn($num).")\n";
			return 1;
		}
		my $rent = $$ref_ents[$i];
		my ($rfuid, $rnuid) = ($$rent[0], $$rent[1]);
		my $rnum = mapmsg($rfuid, $ref_fbs) || mapmsg($rnuid, $ref_nbs);
		if ($i == @$ents) {
			print STDERR "Missing sync state entry $rfuid:$rnuid (".mn($rnum).")\n";
			return 1;
		}
		if ($fuid != $rfuid || $nuid != $rnuid || $num != $rnum) {
			print STDERR "Unexpected sync state entry:".
					" got $fuid:$nuid (".mn($num)."), wanted $rfuid:$rnuid (".mn($rnum).")\n";
			return 1;
		}
		if ($$ent[2] ne $$rent[2]) {
			print STDERR "Flag mismatch in sync state entry $fuid:$nuid (".mn($rnum)."):".
					" got ".mf($$ent[2]).", wanted ".mf($$rent[2])."\n";
			$ret = 1;
		}
	}
	return $ret;
}

# \%actual_chan_state, \%reference_chan_state
sub cmpchan($$)
{
	my ($cs, $ref_cs) = @_;

	my $rslt = 0;
	$rslt |= cmpbox("far", $$cs{far}, $$ref_cs{far});
	$rslt |= cmpbox("near", $$cs{near}, $$ref_cs{near});
	$rslt |= cmptrash("far_trash", $$cs{far_trash}, $$ref_cs{far_trash});
	$rslt |= cmptrash("near_trash", $$cs{near_trash}, $$ref_cs{near_trash});
	$rslt |= cmpstate($cs, $ref_cs);
	return $rslt;
}

# \%box_state
sub printbox($)
{
	my ($bs) = @_;

	my ($mu, $ms) = ($$bs{max_uid}, $$bs{messages});
	print " [ $mu,\n   ";
	my $frst = 1;
	for my $uid (sort { $a <=> $b } keys %$ms) {
		my ($num, $flg) = @{$$ms{$uid}};
		if ($frst) {
			$frst = 0;
		} else {
			print ", ";
		}
		print mn($num).", ".$uid.", \"".$flg."\"";
	}
	print " ],\n";
}

# \%sync_state
sub printstate($)
{
	my ($ss) = @_;

	return if (!$ss);
	print " [ ".$$ss{max_pulled}.", ".$$ss{max_expired_far}.", ".
			$$ss{max_pushed}.", ".$$ss{max_expired_near}.",\n   ";
	my $frst = 1;
	for my $ent (@{$$ss{entries}}) {
		if ($frst) {
			$frst = 0;
		} else {
			print ", ";
		}
		print(($$ent[0] // "??").", ".($$ent[1] // "??").", \"".($$ent[2] // "??")."\"");
	}
	print " ],\n";
}

# \%chan_state
sub printchan($)
{
	my ($cs) = @_;

	printbox($$cs{far});
	printbox($$cs{near});
	printstate($$cs{state});
}

# $run_async, \%source_state, \%target_state, \@channel_configs
sub test_impl($$$$)
{
	my ($async, $sx, $tx, $sfx) = @_;

	mkchan($sx);

	my ($xopt, $xsopt) = @$sfx > 3 ? ($$sfx[3], " ".$$sfx[3]) : ("", "");
	my ($xc, $ret) = runsync($async, "-Tj -TJ".$xsopt, "1-initial.log");
	my $rtx = readchan($$sx{state}) if (!$xc);
	if ($xc || cmpchan($rtx, $tx)) {
		print "Input:\n";
		printchan($sx);
		print "Options:\n";
		print " [ ".join(", ", map('"'.qm($_).'"', @$sfx))." ]\n";
		if (!$xc) {
			print "Expected result:\n";
			printchan($tx);
			print "Actual result:\n";
			printchan($rtx);
		}
		print "Debug output:\n";
		print @$ret;
		exit 1;
	}

	my ($nj, $njl, $nje) = (undef, 0, 0);
	if ($$rtx{state} != $$sx{state}) {
		$nj = readfile("near/.mbsyncstate.journal");
		STEPS: {
			for (reverse @$ret) {
				if (/^### (\d+) steps, (\d+) entries ###$/) {
					$njl = int($1) - 1;
					$nje = int($2);
					last STEPS;
				}
			}
			die("Cannot extract step count.\n");
		}

		my ($jxc, $jret) = runsync($async, "-0 --no-expunge".$xsopt, "2-replay.log");
		my $jrcs = readstate() if (!$jxc);
		if ($jxc || cmpstate({ far => $$tx{far}, near => $$tx{near}, state => $jrcs }, $tx)) {
			print "Journal replay failed.\n";
			print "Options:\n";
			print " [ ".join(", ", map('"'.qm($_).'"', @$sfx))." ], [ \"-0\", \"--no-expunge\" ]\n";
			print "Old State:\n";
			printstate($$sx{state});
			print "Journal:\n".join("", @$nj)."\n";
			if (!$jxc) {
				print "Expected New State:\n";
				printstate($$tx{state});
				print "New State:\n";
				printstate($jrcs);
			}
			print "Debug output:\n";
			print @$jret;
			exit 1;
		}
	}

	my ($ixc, $iret) = runsync($async, $xopt, "3-verify.log");
	my $irtx = readchan() if (!$ixc);
	if ($ixc || cmpchan($irtx, $tx)) {
		print "Idempotence verification run failed.\n";
		print "Input == Expected result:\n";
		printchan($tx);
		print "Options:\n";
		print " [ ".join(", ", map('"'.qm($_).'"', @$sfx))." ]\n";
		if (!$ixc) {
			print "Actual result:\n";
			printchan($irtx);
		}
		print "Debug output:\n";
		print @$iret;
		exit 1;
	}

	rmtree "near";
	rmtree "far";
	rmtree "near_trash";
	rmtree "far_trash";

	for (my $l = 1; $l <= $njl; $l++) {
		mkchan($sx);

		my ($nxc, $nret) = runsync($async, "-Ts$l".$xsopt, "4-interrupt.log");
		if ($nxc != 100 << 8) {
			print "Interrupting at step $l/$njl failed.\n";
			print "Debug output:\n";
			print @$nret;
			exit 1;
		}

		my $pnnj = readfile("near/.mbsyncstate.journal");

		($nxc, $nret) = runsync($async, "-Tj".$xsopt, "5-resume.log");
		my $nrtx = readchan($$sx{state}) if (!$nxc);
		if ($nxc || cmpchan($nrtx, $tx)) {
			print "Resuming from step $l/$njl failed.\n";
			print "Input:\n";
			printchan($sx);
			print "Options:\n";
			print " [ ".join(", ", map('"'.qm($_).'"', @$sfx))." ]\n";
			my $nnj = readfile("near/.mbsyncstate.journal");
			my $ln = $#$pnnj;
			print "Journal:\n".join("", @$nnj[0..$ln])."-------\n".join("", @$nnj[($ln + 1)..$#$nnj])."\n";
			print "Full journal:\n".join("", @$nj[0..$nje])."=======\n".join("", @$nj[($nje + 1)..$#$nj])."\n";
			if (!$nxc) {
				print "Expected result:\n";
				printchan($tx);
				print "Actual result:\n";
				printchan($nrtx);
			}
			print "Debug output:\n";
			print @$nret;
			exit 1;
		}

		rmtree "near";
		rmtree "far";
		rmtree "near_trash";
		rmtree "far_trash";
	}
}

# $title, \@source_state, \@target_state, \@channel_configs, $flip_sides
sub test($$$$;$)
{
	my ($ttl, $isx, $itx, $sfx, $flip) = @_;

	if (@match) {
		if ($start) {
			return if (index($ttl, $match[0]) < 0);
			@match = ();
		} else {
			return if (!grep { index($ttl, $_) >= 0 } @match);
		}
	}

	print "Testing: ".$ttl." ...\n";
	# We don't flip the Store configs, as inverting the Channel config
	# would be unreasonably complex.
	writecfg($sfx);

	my $sx = parse_chan($isx);
	my $tx = parse_chan($itx, $sx);
	if ($flip) {
		flip_chan($sx);
		flip_chan($tx);
	}

	test_impl(0, $sx, $tx, $sfx);
	test_impl(1, $sx, $tx, $sfx);
	test_impl(2, $sx, $tx, $sfx);

	killcfg();
}

################################################################################

# Format of the test defs:
#   ( max_pulled, max_expired, max_pushed, { subject, far, state, near }... )
# Everything is a delta; for the input, the reference is the empty state.
# Common commands:
#   *f => create with flags, appending at end of list
#   / => destroy
#   -f, +f => remove/add flags
# Far/near:
#   Special commands:
#     _ => create phantom message (reserve UID for expunged message)
#     ^f => create with flags, duplicating the subject
#     # => create in trash; deletion may follow
#     | => use zero UID for state modification, even if msg exists; cmd may follow
#     & => use zero UID for state identification, even if message exists
#     &n => use UID of n'th occurence of subject for state id; command may follow
#   Special flag suffixes:
#     * => big
#     ? => placeholder
# State:
#   Special commands:
#     <, > => update far/near message link; flag updates may follow
#     ^f => create with flags, appending right after last command's entry
#   Special flag prefixes as in actual state file.

# Generic syncing tests

my @x01 = (
  I, 0, I,
  P, "_", "*", "_",
  R, "*", "", "",  # Skipped/failed messages to prevent maxuid topping
  S, "", "", "*",
  A, "*F", "*", "*",
  B, "*", "*", "*F",
  C, "*FS", "*", "*F",
  D, "*", "*", "*",
  E, "*T", "*", "*",
  F, "*", "*", "*T",
  O, "*T", "*T", "*T",
  Q, "_", "*T", "*T",
  G, "*F", "*", "_",
  H, "*FT", "*", "*",
  I, "_", "*", "*",
  J, "*T", "", "",
  K, "*P", "", "",
  L, "", "", "*T",
  M, "", "", "*",
);

my @O01 = ("", "", "");
my @X01 = (
  M, 0, K,
  P, "", "/", "",
  A, "", "+F", "+F",
  B, "+F", "+F", "",
  C, "", "+FS", "+S",
  E, "", "+T", "+T",
  F, "+T", "+T", "",
  Q, "", "<", "",
  G, "+T", ">", "",
  H, "", "+FT", "+FT",
  I, "", "<", "+T",
  L, "*T", "*T", "",
  M, "*", "*", "",
  J, "", "*T", "*T",
  K, "", "*P", "*P",
);
test("full", \@x01, \@X01, \@O01);

my @O01a = ("", "", "", "-Tu");
test("full (non-UIDPLUS)", \@x01, \@X01, \@O01a);

my @O02 = ("", "", "Expunge Both\n");
my @X02 = (
  M, 0, K,
  P, "", "/", "",
  A, "", "+F", "+F",
  B, "+F", "+F", "",
  C, "", "+FS", "+S",
  E, "/", "/", "/",
  F, "/", "/", "/",
  O, "/", "/", "/",
  Q, "", "/", "/",
  G, "/", "/", "",
  H, "/", "/", "/",
  I, "", "/", "/",
  J, "/", "", "",
  L, "", "", "/",
  M, "*", "*", "",
  K, "", "*P", "*P",
);
test("full + expunge both", \@x01, \@X02, \@O02);

my @O03 = ("", "", "Expunge Near\n");
my @X03 = (
  M, 0, K,
  P, "", "/", "",
  A, "", "+F", "+F",
  B, "+F", "+F", "",
  C, "", "+FS", "+S",
  E, "", ">+T", "/",
  F, "+T", ">+T", "/",
  O, "", ">", "/",
  Q, "", "/", "/",
  G, "+T", ">", "",
  H, "", ">+T", "/",
  I, "", "/", "/",
  L, "", "", "/",
  M, "*", "*", "",
  K, "", "*P", "*P",
);
test("full + expunge near side", \@x01, \@X03, \@O03);

my @O04 = ("", "", "Sync Pull\n");
my @X04 = (
  K, 0, I,
  P, "", "/", "",  # Only because test uses Maildir driver
  A, "", "+F", "+F",
  C, "", "+FS", "+S",
  E, "", "+T", "+T",
  Q, "", "<", "",
  H, "", "+FT", "+FT",
  I, "", "<", "+T",
  J, "", "*T", "*T",
  K, "", "*P", "*P",
);
test("pull", \@x01, \@X04, \@O04);

my @O05 = ("", "", "Sync Flags\n");
my @X05 = (
  I, 0, I,
  P, "", "/", "",
  A, "", "+F", "+F",
  B, "+F", "+F", "",
  C, "", "+FS", "+S",
  E, "", "+T", "+T",
  F, "+T", "+T", "",
  Q, "", "<", "",
  H, "", "+FT", "+FT",
);
test("flags", \@x01, \@X05, \@O05);

my @O06 = ("", "", "Sync Gone\n");
my @X06 = (
  I, 0, I,
  P, "", "/", "",
  G, "+T", ">", "",
  Q, "", "<", "",
  I, "", "<", "+T",
);
test("gone", \@x01, \@X06, \@O06);

my @O07 = ("", "", "Sync New\n");
my @X07 = (
  M, 0, K,
  L, "*T", "*T", "",
  M, "*", "*", "",
  J, "", "*T", "*T",
  K, "", "*P", "*P",
);
test("new", \@x01, \@X07, \@O07);

my @O08 = ("", "", "Sync PushFlags PullGone\n");
my @X08 = (
  I, 0, I,
  P, "", "/", "",
  B, "+F", "+F", "",
  C, "", "+F", "",
  F, "+T", "+T", "",
  Q, "", "<", "",
  I, "", "<", "+T",
);
test("push flags + pull gone", \@x01, \@X08, \@O08);

my @O09 = ("", "", "Sync None\nExpunge Both\n");
my @X09 = (
  I, 0, I,
  P, "", "/", "",
  E, "/", "", "",
  F, "", "", "/",
  O, "/", "/", "/",
  Q, "", "/", "/",
  H, "/", "", "",
  J, "/", "", "",
  L, "", "", "/",
);
test("noop + expunge both", \@x01, \@X09, \@O09);

my @O0A = ("", "", "Sync None\nExpunge Near\n");
# Sync entries are not updated/pruned, because the far side is not loaded.
my @X0A = (
  I, 0, I,
  F, "", "", "/",
  O, "", "", "/",
  Q, "", "", "/",
  L, "", "", "/",
);
test("noop + expunge near side", \@x01, \@X0A, \@O0A);

# Size restriction tests

my @x20 = (
  0, 0, 0,
  A, "*", "", "",
  B, "*FPS*", "", "",
  C, "", "", "*FS*",
);

my @O21 = ("MaxSize 1k\n", "MaxSize 1k\n", "Sync Full Old\nExpunge Near\n");
my @X21 = (
  C, 0, B,
  C, "*S?", "*<S", "",
  A, "", "*", "*",
  B, "", "*>PS", "*PS?",
);
test("max size", \@x20, \@X21, \@O21);

my @x22 = (
  L, 0, V,
  A, "*", "", "",
  B, "*PR*", "", "",
  V, "*FPR*", "", "",
  C, "*FPR?", "*<DP", "*DP*",
  W, "*FPR?", "*<DP", "*DFP*",
  M, "*FS?", "*<", "**",
  N, "*FS?", "*<S", "**",
  O, "*FS?", "*<S", "*S*",
  P, "*FS?", "*<", "*S*",
  Q, "*F?", "*<S", "*S*",
  R, "*F?", "*<", "*S*",
  S, "*F?", "*<S", "**",
  D, "*PR?", "*<DP", "*DFP*",
  E, "*PR*", "*>DP", "*DP?",
  F, "*S*", "*>", "*?",
  G, "*S*", "*>S", "*?",
  H, "*S*", "*>S", "*S?",
  I, "*S*", "*>", "*S?",
  J, "**", "*>S", "*S?",
  K, "**", "*>", "*S?",
  L, "**", "*>S", "*?",
  A, "", "*", "*",
  B, "", "*>DP", "*DFP?",
  V, "", "*>DP", "*DFP?",
);

my @X22 = (
  S, 0, V,
  B, "", ">->D+R", "^PR*",
  B, "", "", "&1/",
  V, "", ">->D+FR", "^FPR*",
  V, "", "", "&1/",
  C, "^PR*", "<-<D+R", "-D+R",
  C, "&1+T", "^", "&",
  W, "^FPR*", "<-<D+FR", "-D+R",
  W, "&1+T", "^", "&",
  M, "^*", "<-<", "",
  M, "&1+T", "^", "&",
  N, "^*", "<-<S", "",
  N, "&1+T", "^", "&",
  O, "^S*", "<-<", "",
  O, "&1+T", "^", "&",
  P, "^S*", "<-<+S", "",
  P, "&1+T", "^", "&",
  Q, "^*", "<-<S", "-S",
  Q, "&1+T", "^", "&",
  R, "^S*", "<-<+S", "",
  R, "&1+T", "^", "&",
  S, "^*", "<-<S", "",
  S, "&1+T", "^", "&",
  D, "", "-D+R", "-D+R",
  E, "", "-D+R", "-D+R",
  F, "", "+S", "+S",
  G, "-S", "-S", "",
  I, "", "+S", "",
  J, "", "-S", "-S",
  L, "", "-S", "",
);
test("max size + flagging", \@x22, \@X22, \@O21);

my @x24 = (
  C, 0, A,
  A, "*", "*", "*",
  B, "**", "*^", "",
  C, "*FP*", "*^", "",
);

my @X24 = (
  C, 0, C,
  B, "", ">-^+>", "*?",
  C, "", ">-^+>P", "*P?",
);
test("max size (pre-1.4 legacy)", \@x24, \@X24, \@O21);

# Expiration tests

my @x30 = (
  0, 0, 0,
  A, "*F", "", "",
  B, "*", "", "",
  C, "*S", "", "",
  D, "*", "", "",
  E, "*S", "", "",
  F, "*", "", "",
);

my @O31 = ("", "", "MaxMessages 3\n");
my @X31 = (
  F, C, F,
  A, "", "*F", "*F",
  B, "", "*", "*",
  D, "", "*", "*",
  E, "", "*S", "*S",
  F, "", "*", "*",
);
test("max messages", \@x30, \@X31, \@O31);

my @O32 = ("", "", "MaxMessages 3\nExpireUnread yes\n");
my @X32 = (
  F, C, F,
  A, "", "*F", "*F",
  D, "", "*", "*",
  E, "", "*S", "*S",
  F, "", "*", "*",
);
test("max messages vs. unread", \@x30, \@X32, \@O32);

my @x33 = (
  G, D, G,
  A, "*F", "*F", "*F",
  B, "*", "*", "*S",
  C, "*S", "*", "*",
  D, "*S", "", "",
  E, "*", "*", "*S",
  F, "*S", "*S", "*S",
  G, "*", "*", "*S",
  H, "*", "", "",
  I, "*", "", "",
);

my @X33 = (
  I, F, I,
  B, "+S", "+~S", "+T",
  C, "", "+~S", "+ST",
  E, "+S", "+~S", "+T",
  F, "", "+~", "+T",
  G, "+S", "+S", "",
  H, "", "*", "*",
  I, "", "*", "*",
);
test("max messages + expire - full", \@x33, \@X33, \@O31);

my @O31a = ("", "", "MaxMessages 3\nExpireSide Far\n");
test("max messages + expire far - full", \@x33, \@X33, \@O31a, 1);

my @O34 = ("", "", "Sync New\nMaxMessages 3\n");
my @X34 = (
  I, F, I,
  B, "", "+~", "+T",
  E, "", "+~", "+T",
  F, "", "+~", "+T",
  H, "", "*", "*",
  I, "", "*", "*",
);
test("max messages + expire - new", \@x33, \@X34, \@O34);

my @x35 = (
  B, 0, B,
  A, "*F", "*F", "*F",
  B, "*", "*", "*",
  C, "*", "", "",
  D, "*F", "", "",
  E, "*", "", "",
  F, "*", "", "",
  G, "*", "", "",
  H, "*F", "", "",
);

my @O35 = ("", "", "Sync New\nMaxMessages 3\nExpireUnread yes\n");
my @X35 = (
  H, E, H,
  B, "", "+~", "+T",
  D, "", "*F", "*F",
  F, "", "*", "*",
  G, "", "*", "*",
  H, "", "*F", "*F",
);
test("max messages + expire - too many new", \@x35, \@X35, \@O35);

my @x38 = (
  F, C, 0,
  A, "*FS", "*FS", "*S",
  B, "*FS", "*~S", "*ST",
  C, "*S", "*~S", "_",
  D, "*", "*", "*",
  E, "*", "*", "*",
  F, "*", "*", "*",
);

my @O38 = ("", "", "MaxMessages 3\nExpunge Both\n");
my @X38 = (
  F, C, F,
  A, "-F", "/", "/",
  B, "", "-~+F", "-T+F",
  C, "", "/", "",
);
test("max messages + expunge", \@x38, \@X38, \@O38);

# Expiration with size restriction tests

my @x40 = (
  P, 0, P,

  A, "**", "*>", "*?",
  B, "**", "*>", "*S?",
  C, "**", "*>S", "*S?",
  D, "*S*", "*>S", "*S?",
  E, "*S*", "*>", "*S?",
  F, "*S*", "*>S", "*?",
  G, "*S*", "*>", "*?",
  H, "**", "*>S", "*?",

  I, "*F*", "*>", "*?",
  J, "*F*", "*>", "*S?",
  K, "*F*", "*>S", "*S?",
  L, "*FS*", "*>S", "*S?",
  M, "*FS*", "*>", "*S?",
  N, "*FS*", "*>S", "*?",
  O, "*FS*", "*>", "*?",
  P, "*F*", "*>S", "*?",

  Q, "**", "", "",
  R, "*FS*", "", "",
  S, "*S*", "", "",

  T, "**", "", "",
  U, "*FS*", "", "",
  V, "*S*", "", "",
);

my @O41 = ("", "", "MaxSize 1k\nMaxMessages 3\nExpireUnread no\n");
my @X41 = (
  V, S, V,

  C, "", "-S", "-S",
  D, "", "+~", "+T",
  E, "", "+~S", "+T",
  F, "-S", "-S", "",
  G, "", "+~S", "+ST",
  H, "", "-S", "",

  K, "", "-S", "-S",
  M, "", "+S", "",
  N, "-S", "-S", "",
  O, "", "+S", "+S",
  P, "", "-S", "",

  Q, "", "*>", "*?",
  R, "", "*>S", "*S?",

  T, "", "*>", "*?",
  U, "", "*>S", "*S?",
  V, "", "*>S", "*S?",
);
test("max size without upgrade + max messages", \@x40, \@X41, \@O41);

my @x42 = (
  T, Q, T,

  A, "**", "*>", "*F?",
  B, "**", "*>", "*FS?",
  C, "**", "*>S", "*FS?",
  D, "*S*", "*>S", "*FS?",
  E, "*S*", "*>", "*FS?",
  F, "*S*", "*>S", "*F?",
  G, "*S*", "*>", "*F?",
  H, "**", "*>S", "*F?",

  I, "*F*", "*>", "*F?",
  J, "*F*", "*>", "*FS?",
  K, "*F*", "*>S", "*FS?",
  L, "*FS*", "*>S", "*FS?",
  M, "*FS*", "*>", "*FS?",
  N, "*FS*", "*>S", "*F?",
  O, "*FS*", "*>", "*F?",
  P, "*F*", "*>S", "*F?",

  Q, "*S", "", "",

  R, "*", "*", "*",
  S, "*", "*", "*",
  T, "*", "*", "*",
);

my @X43 = (
  T, Q, P,

  A, "", ">->", "^*",
  A, "&", "^", "&1+T",
  B, "", ">->", "^*",
  B, "&", "^", "&1+T",
  C, "", ">->S", "^*",
  C, "&", "^", "&1+T",
  D, "", "/", "",
  D, "&", "^", "&1+T",
  E, "", "/", "",
  E, "&", "^", "&1+T",
  F, "-S", ">->S", "^*",
  F, "&", "^", "&1+T",
  G, "", "/", "",
  G, "&", "^", "&1+T",
  H, "", ">->S", "^*",
  H, "&", "^", "&1+T",

  I, "", ">->+F", "^F*",
  I, "&", "^", "&1+T",
  J, "", ">->+F", "^F*",
  J, "&", "^", "&1+T",
  K, "", ">->S+F", "^F*",
  K, "&", "^", "&1+T",
  L, "", ">->+F", "^FS*",
  L, "&", "^", "&1+T",
  M, "", ">->+FS", "^FS*",
  M, "&", "^", "&1+T",
  N, "-S", ">->S+F", "^F*",
  N, "&", "^", "&1+T",
  O, "", ">->+FS", "^FS*",
  O, "&", "^", "&1+T",
  P, "", ">->S+F", "^F*",
  P, "&", "^", "&1+T",
);
test("max size with upgrade + max messages", \@x42, \@X43, \@O41);

# Test for legacy/tampered states with inaccurate maxuid tracking

# Joined post-push & post-pull state to have just one test -
# there is no way how this could have occurred naturally.
my @x60 = (
  0, C, 0,
  A, "*S", "", "_",
  B, "*FS", "*FS", "*FS",
  C, "*S", "", "_",
  D, "*", "*", "*",
  E, "*", "*", "*",
  F, "*", "", "",
  G, "*", "", "",
  H, "", "", "*",
  I, "", "", "_",
  J, "*", "*", "*",
);

my @O61 = ("", "", "Sync Flags\n");  # Need to fetch old messages
my @X61 = (
  E, C, E,
);
test("maxuid topping", \@x60, \@X61, \@O61);

my @O62 = ("", "", "Sync Flags\nExpireSide Far");
test("maxuid topping (expire far)", \@x60, \@X61, \@O62, 1);

# Tests for refreshing previously skipped/failed/expired messages.
# We don't know the flags at the time of the (hypothetical) previous
# sync, so we can't know why a particular message is missing.
# We test with MaxMessages to cover different behaviors wrt maxxfuid.

my @x70 = (
  L, E, P,
  A, "*", "", "",
  B, "*F", "", "",
  C, "", "", "*",
  D, "*F", "*F", "*F",
  E, "*", "", "_",      # MaxExpiredFarUid
  F, "*", "*", "*",
  G, "_", "*T", "*T",
  H, "*T", "*T", "_",
  I, "", "", "*T",
  J, "", "", "*",
  K, "*T", "", "",
  L, "*", "", "",       # MaxPulledUid
  M, "_", "*T", "*T",
  N, "*T", "*T", "_",
  O, "", "", "*T",
  P, "", "", "*",       # MaxPushedUid
  Q, "*T", "", "",
  R, "*", "", "",
  S, "", "", "*",
);

my @O71 = ("", "", "Sync New\nMaxMessages 20\nExpireUnread yes\n");
my @X71 = (
  S, E, R,
  N, "", ">", "",
  S, "*", "*", "",
  Q, "", "*T", "*T",
  R, "", "*", "*",
);
test("not old", \@x70, \@X71, \@O71);

my @O71a = ("", "", "Sync New\nMaxMessages 3\nExpireUnread yes\n");
test("not old + expire", \@x70, \@X71, \@O71a);

my @O72 = ("", "", "Sync New Old\nMaxMessages 20\nExpireUnread yes\nExpunge Near\n");
my @X72 = (
  S, E, R,
  G, "", "/", "/",
  H, "", ">", "",
  I, "", "", "/",
  M, "", "/", "/",
  N, "", ">", "",
  O, "", "", "/",
  C, "*", "*", "",
  J, "*", "*", "",
  P, "*", "*", "",
  S, "*", "*", "",
  B, "", "*F", "*F",
  L, "", "*", "*",
  R, "", "*", "*",
);
test("old + expunge near", \@x70, \@X72, \@O72);

# This omits the entries that cause idempotence problems
# due to not counting/expiring newly pushed messages.
my @x70a = (
  L, E, O,
  A, "*", "", "",
  B, "*F", "", "",
  D, "*F", "*F", "*F",
  E, "*", "", "_",      # MaxExpiredFarUid
  G, "_", "*T", "*T",
  H, "*T", "*T", "_",
  I, "", "", "*T",
  K, "*T", "", "",
  L, "*", "", "",       # MaxPulledUid
  M, "_", "*T", "*T",
  N, "*T", "*T", "_",
  O, "", "", "*T",      # MaxPushedUid
  Q, "*T", "", "",
  R, "*", "", "",
  S, "", "", "*",
);

my @O72a = ("", "", "Sync New Old\nMaxMessages 3\nExpireUnread yes\nExpunge Near\n");
my @X72a = (
  S, E, R,
  G, "", "/", "/",
  H, "", ">", "",
  I, "", "", "/",
  M, "", "/", "/",
  N, "", ">", "",
  O, "", "", "/",
  S, "*", "*", "",
  B, "", "*F", "*F",
  L, "", "*", "*",
  R, "", "*", "*",
);
test("old + expire + expunge near", \@x70a, \@X72a, \@O72a);

my @O73 = ("", "", "Sync Pull New Old\nMaxMessages 20\nExpireUnread yes\n");
my @X73 = (
  R, E, P,
  B, "", "*F", "*F",
  G, "", "<", "",
  H, "", ">", "",
  K, "", "*T", "*T",
  L, "", "*", "*",
  M, "", "<", "",
  N, "", ">", "",
  Q, "", "*T", "*T",
  R, "", "*", "*",
);
test("pull old", \@x70, \@X73, \@O73);

# This is "weird", because expiration overtook pulling.
my @x80 = (
  D, L, Q,
  A, "", "", "*",
  B, "*", "", "",
  C, "*T", "", "",
  D, "*F", "", "",      # MaxPulledUid
  E, "_", "*T", "*T",
  F, "*T", "*T", "_",
  G, "", "", "*T",
  H, "", "", "*",
  I, "*T", "", "",
  J, "*", "", "",
  K, "*F", "*F", "*F",
  L, "*", "*~", "_",    # MaxExpiredFarUid
  M, "*", "*", "*",
  N, "_", "*T", "*T",
  O, "*T", "*T", "_",
  P, "", "", "*T",
  Q, "", "", "*",       # MaxPushedUid
  R, "*T", "", "",
  S, "*", "", "",
  T, "", "", "*T",
  U, "", "", "*",
);

my @X81 = (
  U, L, S,
  F, "", ">", "",
  L, "", "/", "",
  O, "", ">", "",
  T, "*T", "*T", "",
  U, "*", "*", "",
  I, "", "*T", "*T",
  J, "", "*", "*",
  R, "", "*T", "*T",
  S, "", "*", "*",
);
test("weird not old", \@x80, \@X81, \@O71);

my @X81a = (
  U, L, S,
  F, "", ">", "",
  L, "", "/", "",
  O, "", ">", "",
  T, "*T", "*T", "",
  U, "*", "*", "",
  I, "", "*T", "*T",
  R, "", "*T", "*T",
  S, "", "*", "*",
);
test("weird not old + expire", \@x80, \@X81a, \@O71a);

my @X82 = (
  U, L, S,
  E, "", "/", "/",
  F, "", ">", "",
  G, "", "", "/",
  L, "", "/", "",
  N, "", "/", "/",
  O, "", ">", "",
  P, "", "", "/",
  T, "", "", "/",
  A, "*", "*", "",
  H, "*", "*", "",
  Q, "*", "*", "",
  U, "*", "*", "",
  D, "", "*F", "*F",
  J, "", "*", "*",
  S, "", "*", "*",
);
test("weird old + expunge near", \@x80, \@X82, \@O72);

my @x80a = (
  D, L, Q,
  B, "*", "", "",
  C, "*T", "", "",
  D, "*F", "", "",      # MaxPulledUid
  E, "_", "*T", "*T",
  F, "*T", "*T", "_",
  G, "", "", "*T",
  H, "", "", "*",
  I, "*T", "", "",
  K, "*F", "*F", "*F",
  L, "*", "*~", "_",    # MaxExpiredFarUid
  N, "_", "*T", "*T",
  O, "*T", "*T", "_",
  P, "", "", "*T",
  Q, "", "", "*",       # MaxPushedUid
  R, "*T", "", "",
  T, "", "", "*T",
  U, "", "", "*",
);

my @X82a = (
  U, L, D,
  E, "", "/", "/",
  F, "", ">", "",
  G, "", "", "/",
  L, "", "/", "",
  N, "", "/", "/",
  O, "", ">", "",
  P, "", "", "/",
  T, "", "", "/",
  H, "*", "*", "",
  Q, "*", "*", "",
  U, "*", "*", "",
  D, "", "*F", "*F",
);
test("weird old + expire + expunge near", \@x80a, \@X82a, \@O72a);

my @O82b = ("", "", "Sync New Old\nMaxMessages 3\nExpireUnread yes\nExpireSide Far\nExpunge Far\n");
my @X82b = (
  U, L, D,
  E, "", "/", "/",
  F, "", ">", "",
  G, "", "", "/",
  L, "", "/", "",
  N, "", "/", "/",
  O, "", ">", "",
  P, "", "", "/",
  T, "", "", "/",
  D, "", "*F", "*F",
  H, "*", "*", "",
  Q, "*", "*", "",
  U, "*", "*", "",
);
test("weird old + expire far + expunge far", \@x80a, \@X82b, \@O82b, 1);

my @X83 = (
  S, L, Q,
  E, "", "<", "",
  F, "", ">", "",
  L, "", "/", "",
  N, "", "<", "",
  O, "", ">", "",
  D, "", "*F", "*F",
  I, "", "*T", "*T",
  J, "", "*", "*",
  R, "", "*T", "*T",
  S, "", "*", "*",
);
test("weird pull old", \@x80, \@X83, \@O73);

# Messages that would be instantly expunged on the target side.

my @x90 = (
  C, 0, C,
  A, "*DRT*", "*>DS", "*DFPS?",
  B, "*DR*", "*>DS", "*DFPST?",
  C, "*", "*", "*",
  D, "*T", "", "",
);

my @O91 = ("", "", "Expunge Near\n", "-Tx");
my @X91 = (
  D, 0, C,
  A, "+P", ">+P", "|",
  A, "&", "^", "+T",
  B, "+PT", ">+PT", "|",
  B, "&", "^", "",
);
test("doomed", \@x90, \@X91, \@O91);

# Trashing

my @x10 = (
  K, A, K,
  A, "*", "*~", "*T",
  B, "*T", "*^", "",
  C, "*T", "*", "*T",
  D, "_", "*", "*",
  E, "*", "*", "_",
  F, "**", "*>", "*T?",
  G, "*T?", "*<", "**",
  H, "**", "*>", "*FT?",
  I, "*FT?", "*<", "**",
  J, "**", "*>", "*F?",
  K, "*F?", "*<", "**",
  L, "*T", "", "",
  M, "", "", "*T",
  R, "", "", "*",  # Force maxuid in the interrupt-resume test.
  S, "*", "", "",
);

my @O11 = ("Trash far_trash\n", "Trash near_trash\n",
           "MaxMessages 20\nExpireUnread yes\nMaxSize 1k\nExpunge Both\n");
my @X11 = (
  R, A, S,
  A, "", "/", "/",
  B, "#/", "/", "",
  C, "#/", "/", "#/",
  D, "", "/", "#/",
  E, "#/", "/", "",
  F, "#/", "/", "/",
  G, "/", "/", "#/",
  H, "#/", "/", "/",
  I, "/", "/", "#/",
  J, "", ">->", "^*",
  J, "", "", "&1/",
  K, "^*", "<-<", "",
  K, "&1/", "", "",
  L, "#/", "", "",
  M, "", "", "#/",
  R, "*", "*", "",
  S, "", "*", "*",
);
test("trash", \@x10, \@X11, \@O11);

my @O12 = ("Trash far_trash\n", "Trash near_trash\nTrashNewOnly true\n",
           "MaxMessages 20\nExpireUnread yes\nMaxSize 1k\nExpunge Both\n");
my @X12 = (
  R, A, S,
  A, "", "/", "/",
  B, "#/", "/", "",
  C, "#/", "/", "/",
  D, "", "/", "/",
  E, "#/", "/", "",
  F, "#/", "/", "/",
  G, "/", "/", "#/",
  H, "#/", "/", "/",
  I, "/", "/", "#/",
  J, "", ">->", "^*",
  J, "", "", "&1/",
  K, "^*", "<-<", "",
  K, "&1/", "", "",
  L, "#/", "", "",
  M, "", "", "#/",
  R, "*", "*", "",
  S, "", "*", "*",
);
test("trash only new", \@x10, \@X12, \@O12);

my @O13 = ("Trash far_trash\nTrashRemoteNew true\n", "",
           "MaxMessages 20\nExpireUnread yes\nMaxSize 1k\nExpunge Both\n");
my @X13 = (
  R, A, S,
  A, "", "/", "/",
  B, "#/", "/", "",
  C, "#/", "/", "/",
  D, "", "/", "/",
  E, "#/", "/", "",
  F, "#/", "/", "/",
  G, "#/", "/", "/",
  H, "#/", "/", "/",
  I, "#/", "/", "/",
  J, "", ">->", "^*",
  J, "", "", "&1/",
  K, "^*", "<-<", "",
  K, "&1/", "", "",
  L, "#/", "", "",
  M, "#", "", "/",
  R, "*", "*", "",
  S, "", "*", "*",
);
test("trash new remotely", \@x10, \@X13, \@O13);

my @O14 = ("Trash far_trash\n", "",
           "Sync Flags Gone\nMaxMessages 20\nExpireUnread yes\nExpireSide Far\nMaxSize 1k\nExpunge Both\n");
my @X14 = (
  K, A, K,
  A, "", "/", "/",
  B, "/", "/", "",
  C, "/", "/", "#/",
  D, "", "/", "#/",
  E, "/", "/", "",
  F, "/", "/", "/",
  G, "/", "/", "#/",
  H, "/", "/", "/",
  I, "/", "/", "#/",
  L, "/", "", "",
  M, "", "", "#/",
);
test("trash near (expire far)", \@x10, \@X14, \@O14, 1);

# Test "mirroring" expunges.

my @xa0 = (
  M, 0, M,
  # pair
  A, "*", "*", "*",
  # expire
  B, "*", "*", "*S",
  # expire with del
  C, "*T", "*", "*S",
  # pair flag del
  D, "*T", "*", "*",
  E, "*", "*", "*T",
  # pair flag undel
  F, "*", "*T", "*T",
  G, "*T", "*T", "*",
  # pair gone
  H, "_", "*", "*",
  I, "*", "*", "_",
  # upgrade
  J, "**", "*>", "*F?",
  K, "*F?", "*<", "**",
  # doomed upgrade
  L, "*T*", "*>", "*F?",
  M, "*F?", "*<", "*T*",
  # doomed new
  N, "", "", "*T",
  O, "*T", "", "",
);

my @Oa1 = ("", "", "ExpungeSolo Both\nMaxMessages 1\nExpireUnread false\n");
my @Xa1 = (
  N, B, O,
  B, "+S", "/", "/",
  C, "+S", "+ST", "+T",  # This is weird, but it's not worth handling.
  D, "", "+T", "+T",
  E, "+T", "+T", "",
  F, "", "-T", "-T",
  G, "-T", "-T", "",
  H, "", "/", "/",
  I, "/", "/", "",
  J, "", ">->", "^*",
  J, "", "", "&1/",
  K, "^*", "<-<", "",
  K, "&1/", "", "",
  L, "", ">->+T", "^*T",
  L, "", "", "&1/",
  M, "^*T", "<-<+T", "",
  M, "&1/", "", "",
  N, "*T", "*T", "",
  O, "", "*T", "*T",
);
test("expunge solo both", \@xa0, \@Xa1, \@Oa1);

my @Oa2 = ("", "", "ExpungeSolo Near\nMaxMessages 1\nExpireUnread false\n");
my @Xa2 = (
  N, B, O,
  B, "+S", "/", "/",
  C, "+S", "+ST", "+T",  # As above.
  D, "", "+T", "+T",
  E, "+T", "+T", "",
  F, "", "-T", "-T",
  G, "-T", "-T", "",
  H, "", "/", "/",
  I, "+T", ">", "",
  J, "", ">->", "^*",
  J, "", "", "&1/",
  K, "^*", "<-<", "",
  K, "&1+T", "^", "|",
  L, "", ">->+T", "^*T",
  L, "", "", "&1/",
  M, "^*T", "<-<+T", "",
  M, "&1+T", "^", "|",
  N, "*T", "*T", "",
  O, "", "*T", "*T",
);
test("expunge solo near", \@xa0, \@Xa2, \@Oa2);

my @Oa3 = ("", "", "Expunge Far\nExpungeSolo Near\nMaxMessages 1\nExpireUnread false\n");
my @Xa3 = (
  K, B, J,
  B, "+S", "/", "/",
  C, "/", "/", "/",
  D, "/", "/", "/",
  E, "/", "/", "/",
  F, "", "-T", "-T",
  G, "-T", "-T", "",
  H, "", "/", "/",
  I, "/", "/", "",
  J, "", ">->", "^*",
  J, "", "", "&1/",
  K, "^*", "<-<", "",
  K, "&1/", "", "",
  L, "/", "/", "/",
  M, "/", "/", "/",
  N, "", "", "/",
  O, "/", "", "",
);
test("expunge far & solo near", \@xa0, \@Xa3, \@Oa3);

print "OK.\n";
