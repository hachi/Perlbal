#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use IO::Socket::INET;
use Test::More 'no_plan';

# setup webserver
my $web_port = start_webserver();
ok($web_port, 'webserver started');

# setup perlbal
my $port = new_port();
my $dir = tempdir();

my $conf = qq{
SERVER aio_mode = none

CREATE POOL a
POOL a ADD 127.0.0.1:$web_port

CREATE SERVICE test
SET role = reverse_proxy
SET pool = a
SET connect_ahead = 0
SET listen = 127.0.0.1:$port
SET persist_client = 1
SET buffer_uploads_path = $dir
SET buffer_uploads = 1
ENABLE test
};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

ok(! buffer_file_exists(), "no files in buffer directory");

# setup data
my $data = 'x' x 1_000_000;
my ($curpos, $clen) = (0, 0);

my $req;

# disable all of it
request("buffer_off", 500_000,
        "write:500",
        "write:5",
        "write:5",
        "write:5",
        "sleep:0.25",
        "exists",
        "write:100000",
        "write:60000",
        "write:1000",
        "finish",
        sub {
            my ($res) = @_;
            my $cont = $res->content;
            like($cont, qr/length = 500000/, "backend got right content-length");
        },
        "empty");

sub buffer_file_exists {
    opendir DIR, $dir
        or die "can't open dir\n";
    foreach (readdir(DIR)) {
        next if /^\./;
        return 1;
    }
    return 0;
}

# cmds can be:
#    write:<length>     writes <length> bytes
#    sleep:<duration>   sleeps <duration> seconds, may be fractional
#    finish             (sends any final writes and/or reads response)
#    close              close socket
#    sub {}             coderef to run.  gets passed response object
#    no-reason          response has no reason
#    reason:<reason>    did buffering for either "size", "rate", or "time"
#    empty              No files in temp buffer location
#    exists             Yes, a temporary file exists
sub request {
    my $testname = shift;
    my $len = shift || 0;
    my @cmds = @_;

    my $curpos = 0;
    my $remain = $len;

    my $hdr = "POST /status HTTP/1.0\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n";
    my $sock = IO::Socket::INET->new( PeerAddr => "127.0.0.1:$port" )
        or return undef;
    my $rv = syswrite($sock, $hdr);
    die unless $rv == length($hdr);

    # wanting HTTP/1.1 100 Continue\r\n...\r\n lines
    {
        my $contline = <$sock>;
        die "didn't get 100 Continue line, got: $contline"
            unless $contline =~ m!^HTTP/1.1 100!;
        my $gotempty = 0;
        while (defined(my $line = <$sock>)) {
            if ($line eq "\r\n") {
                $gotempty = 1;
                last;
            }
        }
        die "didn't get empty line after 100 Continue" unless $gotempty;
    }

    my $res = undef;  # no response yet

    foreach my $cmd (@cmds) {
        my $writelen;

        if ($cmd =~ /^write:([\d_]+)/) {
            $writelen = $1;
            $writelen =~ s/_//g;
        } elsif ($cmd =~ /^(\d+)/) {
            $writelen = $1;
        } elsif ($cmd eq "finish") {
            $writelen = $remain;
        }

        if ($cmd =~ /^sleep:([\d\.]+)/) {
            select undef, undef, undef, $1;
            next;
        }

        if ($cmd eq "close") {
            close($sock);
            next;
        }

        if ($cmd eq "exists") {
            ok(buffer_file_exists(), "$testname: buffer file exists");
            next;
        }

        if ($cmd eq "empty") {
            ok(! buffer_file_exists(), "$testname: no file");
            next;
        }

        if ($writelen) {
            die "Too long" if $writelen > $remain;
            my $buf = "x" x $writelen;
            $buf = sprintf("%x\r\n", $writelen) . $buf . "\r\n";
            $remain -= $writelen;
            if ($remain == 0) {
                # one \r\n for chunk ending, one for chunked-body ending,
                # after (our empty) trailer...
                $buf .= "0\r\n\r\n";
            }
            my $bufsize = length($buf);
            my $off = 0;
            while ($off < $bufsize) {
                my $rv = syswrite($sock, $buf, $bufsize-$off, $off);
                die "Error writing: $!" unless defined $rv;
                die "Got rv=0 from syswrite" unless $rv;
                $off += $rv;
            }

            next unless $cmd eq "finish";
        }

        if ($cmd eq "finish") {
            $res = resp_from_sock($sock);
            my $clen = $res ? $res->header('Content-Length') : 0;
            ok($res && length($res->content) == $clen, "$testname: good response");
            next;
        }

        if (ref $cmd eq "CODE") {
            $cmd->($res, $testname);
            next;
        }

        die "Invalid command: $cmd\n";
    }
}

1;
