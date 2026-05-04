#!/usr/bin/env perl
use warnings;
use strict;
use Config;
use BuildHelper;
use Fcntl qw(:flock O_RDWR O_CREAT);

my $verbose = 0;
my $jobs    = 1;
my $PERL    = "/usr/bin/perl";
my $TARGET  = "/tmp/thruk_p5_dist";
my $DISTRO  = "";

while (@ARGV) {
    if($ARGV[0] =~ m/perl$/) { $PERL    = shift @ARGV; next; }
    if($ARGV[0] eq '-v')     { $verbose = 1; shift @ARGV; next; }
    if($ARGV[0] eq '-d')     { shift @ARGV; $DISTRO = shift @ARGV; next; }
    if($ARGV[0] eq '-p')     { shift @ARGV; $TARGET = shift @ARGV; next; }
    if($ARGV[0] eq '-j')     { shift @ARGV; $jobs   = int(shift @ARGV); $jobs = 1 if $jobs < 1; next; }
    last; # remaining args are module filenames
}

chomp($DISTRO = `./build/distro`) unless $DISTRO;

# Set inner make parallelism unless the caller already configured MAKE.
# In serial mode (-j 1) use all cores inside each module.
# In parallel mode (-j N) allow modest oversubscription so heavy XS modules
# (DBD-SQLite, CryptX, …) can still use more than one compiler thread.
unless ($ENV{MAKE}) {
    chomp(my $nproc = `nproc 2>/dev/null || echo 1`);
    $nproc = int($nproc) || 1;
    my $inner = $jobs <= 1 ? $nproc : int($nproc / $jobs) + 1;
    $inner = 1 if $inner < 1;
    $ENV{MAKE} = "make -j$inner";
}

if(!defined $ENV{'PERL5LIB'} or $ENV{'PERL5LIB'} eq "") {
    print "dont call $0 directly, use the 'make'\n";
    exit 1;
}

my @mods;
for my $mod (@ARGV) {
    next if $mod =~ m/curl/mxi and $DISTRO =~ m/^rhel5/mxi;
    next if $mod =~ m/curl/mxi and $DISTRO =~ m/^CENTOS\ 5/mxi;
    next if $mod =~ m/Term-ReadLine-Gnu/mxi and $DISTRO =~ m/^UBUNTU\ 10/mxi;
    push @mods, $mod;
}

my $max = scalar @mods;

if ($jobs <= 1) {
    my $x = 1;
    for my $mod (@mods) {
        BuildHelper::install_module($mod, $TARGET, $PERL, $verbose, $x, $max, $ENV{'FORCE'}) || exit 1;
        $x++;
    }
    exit 0;
}

# Parallel execution: $jobs forked workers share a queue file
# Workers consume modules in list order (which is already dependency-ordered).
# Each module installs into its own namespace under dest/, so there are no
# filesystem conflicts between parallel workers.
my $parent_pid = $$;
my $queue_file = "$TARGET/.build_queue";
{
    open(my $fh, '>', $queue_file) or die "Cannot create queue file: $!";
    printf $fh "%010d\n", 0;
    close($fh);
}
END { unlink $queue_file if defined $queue_file && $$ == $parent_pid && -f $queue_file }

my %pids;
for (1 .. $jobs) {
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        local $SIG{TERM} = sub { exit 0 };
        while (1) {
            my $idx = _claim_next($queue_file);
            last if $idx >= $max;
            my $mod = $mods[$idx];
            my $ok  = eval { BuildHelper::install_module($mod, $TARGET, $PERL, $verbose, $idx + 1, $max, $ENV{'FORCE'}) };
            if ($@ || !$ok) {
                warn $@ if $@;
                exit 1;
            }
        }
        exit 0;
    }
    $pids{$pid} = 1;
}

my $failed = 0;
while (%pids) {
    my $pid = wait();
    last if $pid == -1;
    if ($? != 0) {
        $failed = 1;
        kill('TERM', $_) for grep { $_ != $pid } keys %pids;
    }
    delete $pids{$pid};
}
exit $failed ? 1 : 0;

sub _claim_next {
    my ($f) = @_;
    sysopen(my $fh, $f, O_RDWR) or die "open queue: $!";
    flock($fh, LOCK_EX)         or die "lock queue: $!";
    my $line = <$fh> // '0000000000';
    chomp $line;
    my $idx = int($line);
    seek($fh, 0, 0);
    printf $fh "%010d\n", $idx + 1;
    flock($fh, LOCK_UN);
    close($fh);
    return $idx;
}
