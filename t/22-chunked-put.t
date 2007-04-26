#!/usr/bin/perl

use strict;
use Perlbal::Test;
use IO::Socket::INET;
use Test::More 'no_plan';

my $port = new_port();
my $dir = tempdir();

my $conf = qq{
SERVER aio_mode = none

CREATE SERVICE test
SET test.role = web_server
SET test.listen = 127.0.0.1:$port
SET test.docroot = $dir
SET test.dirindexing = 0
SET test.enable_put = 1
SET test.enable_delete = 1
SET test.min_put_directory = 0
SET test.persist_client = 1
ENABLE test
};

my $msock = start_server($conf);

my $ua = ua();
ok($ua);

require HTTP::Request;

my $url = "http://127.0.0.1:$port/foo.txt";
my $disk_file = "$dir/foo.txt";
my $contentlen = 0;
my $written_content = "";

sub buffer_file_exists {
    -e $disk_file;
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

    $contentlen = 0;
    $written_content = "";

    my $hdr = "PUT /foo.txt HTTP/1.0\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n";
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

        if ($writelen) {
            diag("Writing: $writelen");
            die "Too long" if $writelen > $remain;
            my $buf = chr(int(rand(26)) + 65) x $writelen;

            # update what we'll be checking for later,
            $contentlen += $writelen;
            $written_content .= $buf;

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
                die "Error writing: $!, we had finished $off of $bufsize" unless defined $rv;
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

sub delete_file {
    my $req = HTTP::Request->new(DELETE => $url);
    my $res = $ua->request($req);
    return $res->is_success;
}

sub verify_put {
    open(my $fh, $disk_file) or die;
    my $slurp = do { local $/; <$fh>; };
    ok(-s $disk_file == $contentlen && $slurp eq $written_content, "verified put");
}

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
            verify_put();
        },
        );

1;
