package Perlbal::Test;
use strict;
use POSIX qw( :sys_wait_h );
use IO::Socket::INET;
use HTTP::Response;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(ua start_server foreach_aio manage filecontent tempdir new_port
             mgmt_port wait_on_child dump_res resp_from_sock msock);

our $i_am_parent = 0;
our $msock;  # management sock of child
our $to_kill = 0;
our $mgmt_port;

our $free_port = 60000;

sub mgmt_port { return $mgmt_port; }

END {
    manage("shutdown") if $i_am_parent;
}

sub dump_res {
    my $res = shift;
    my ($pkg, $filename, $line) = caller;
    my $ret = "$filename:$line ==> ";
    unless ($res) {
        $ret .= "[response undefined]\n";
        return $ret;
    }
    my $ct = $res->content;
    my $len = length $ct;
    if ($len > 80) {
        $ct = substr($ct, 0, 80) . "...";
    }
    my $status = $res->status_line;
    $status =~ s/[\r\n]//g;
    return $ret . "status=[$status] content=$len" . "[$ct]\n";
}

sub tempdir {
    require File::Temp;
    return File::Temp::tempdir( CLEANUP => 1 );
}

sub new_port {
    return $free_port++;  # FIXME: make it somehow detect if port is in use?
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
    $mgmt_port = new_port();

    if ($ENV{'TEST_PERLBAL_FOREGROUND'}) {
        _start_perbal_server($conf, $mgmt_port);
    }

    if ($ENV{'TEST_PERLBAL_USE_EXISTING'}) {
        my $msock = wait_on_child(0, $mgmt_port);
        return $msock;
    }

    my $child = fork;
    if ($child) {
        $i_am_parent = 1;
        $to_kill = $child;
        my $msock = wait_on_child($child, $mgmt_port);
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
    _start_perbal_server($conf, $mgmt_port);
}

sub _start_perbal_server {
    my ($conf, $mgmt_port) = @_;

    require Perlbal;

    $conf .= qq{
CREATE SERVICE mgmt
SET mgmt.listen = 127.0.0.1:$mgmt_port
SET mgmt.role = management
ENABLE mgmt
};

    my $out = sub { print STDOUT "$_[0]\n"; };
    die "Configuration error" unless Perlbal::run_manage_commands($conf, $out);

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
    my $port = shift;

    my $start = time;
    while (1) {
        $msock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port");
        return $msock if $msock;
        select undef, undef, undef, 0.25;
        if ($pid && waitpid($pid, WNOHANG) > 0) {
            die "Child process (webserver) died.\n";
        }
        die "Timeout waiting for port $port to startup" if time > $start + 5;
    }
}

sub resp_from_sock {
    my $sock = shift;

    my $res = "";
    my $firstline = undef;

    while (<$sock>) {
        $res .= $_;
        $firstline ||= $_;
        last if ! $_ || /^\r?\n/;
    }

    unless ($firstline) {
        print STDERR "Didn't get a firstline in HTTP response.\n";
        return undef;
    }

    my $resp = HTTP::Response->parse($res);
    return undef unless $resp;

    my $cl = $resp->header('Content-Length');
    if (defined $cl && $cl > 0) {
        my $content = '';
        while (($cl -= read($sock, $content, $cl)) > 0) {
            # don't do anything, the loop is it
        }
        $resp->content($content);
    }

    return wantarray ? ($resp, $firstline) : $resp;
}

1;
