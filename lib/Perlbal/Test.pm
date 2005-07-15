package Perlbal::Test;
use strict;
use POSIX qw( :sys_wait_h );
use IO::Socket::INET;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(ua start_server foreach_aio manage filecontent);

our $i_am_parent = 0;
our $msock;  # management sock of child
our $to_kill = 0;

END {
    manage("shutdown") if $i_am_parent;
}

sub filecontent {
    my $file = shift;
    my $ct;
    open (F, $file) or return undef;
    $ct = do { local $/; <F>; };
    close F;
    return $ct;
}

sub foreach_aio (&) {
    my $cb = shift;

    foreach my $mode (qw(none linux ioaio)) {
        my $line = manage("SERVER aio_mode = $mode");
        next unless $line;
        $cb->($mode);
    }
}

sub manage {
    my $cmd = shift;
    print $msock "$cmd\r\n";
    my $res = <$msock>;
    return 0 if !$res || $res =~ /^ERR/;
    return $res;
}

sub start_server {
    my $conf = shift;

    my $child = fork;
    if ($child) {
        $i_am_parent = 1;
        $to_kill = $child;
        my $msock = wait_on_child($child);
        my $rv = waitpid($child, WNOHANG);
        if ($rv) {
            die "Child process (webserver) died.\n";
        }
        print $msock "proc\r\n";
        my $spid = undef;
        while (<$msock>) {
            last if m!^\.\r?\n!;
            next unless /^pid:\s+(\d+)/;
            $spid = $1;
        }
        die "Our child was $child, but we connected and it says it's $spid."
            unless $child == $spid;

        return $msock;
    }

    # child process...

    require Perlbal;

    $conf .= qq{
CREATE SERVICE mgmt
SET mgmt.listen = 127.0.0.1:60000
SET mgmt.role = management
ENABLE mgmt
};

    my $out = sub { print STDOUT join("\n", map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_) . "\n"; };
    Perlbal::run_manage_command($_, $out) foreach split(/\n/, $conf);

    unless (Perlbal::Socket->WatchedSockets() > 0) {
        die "Invalid configuration.  (shouldn't happen?)  Stopping (self=$$).\n";
    }

    Perlbal::run();
    exit 0;
}

# get the manager socket
sub msock {
    return $msock;
}

sub ua {
    require LWP;
    require LWP::UserAgent;
    return LWP::UserAgent->new;
}

sub wait_on_child {
    my $pid = shift;

    my($port) = @_;
    my $start = time;
    while (1) {
	$msock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:60000");
	return $msock if $msock;
	select undef, undef, undef, 0.25;
        if (waitpid($pid, WNOHANG) > 0) {
            die "Child process (webserver) died.\n";
        }
	die "Timeout waiting for port $port to startup" if time > $start + 5;
    }
}

1;
