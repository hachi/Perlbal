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
buffer_rules();

# post our data, should not create buffer file
my $resp = quick_request(100_000);
ok(pid_of_resp($resp), "posting works");
ok(! buffer_file_exists(), "no files in buffer, good");

# try writing 400k of a 500k file, and set the buffer size to be "anything
# larger than 400k"
buffer_rules(size => 400_000);
request(500_000,
        400_000,
        sub {
            ok(buffer_file_exists(), "files in buffer, good");
        },
        "finish",
        sub {
            my $res = shift;
            like(buf_reason($res), qr/^size/);
            ok(! buffer_file_exists(), "buffer cleaned up");
        },
        );

# write a file below the limit
request(200_000,
        100_000,
        sub {
            ok(! buffer_file_exists(), "no file");
        },
        "finish",
        sub {
            my $res = shift;
            ok(! buf_reason($res));
            ok(! buffer_file_exists(), "buffer still empty");
        },
        );

sub buf_reason {
    my $resp = shift;
    return "" unless $resp && $resp->content =~ /^buffered = (\S+)$/m;
    return $1;

}

sub buffer_rules {
    my %opts = @_;
    my $size = delete $opts{size};
    my $rate = delete $opts{rate};
    my $time = delete $opts{time};
    die "bogus opts" if %opts;

    # if they don't provide a value, set it to 0, which means threshold ignored
    set_threshold('size', $size || 0);
    set_threshold('rate', $rate || 0);
    set_threshold('time', $time || 0);
}

sub set_threshold {
    my ($which, $what) = @_;
    manage("SET test.buffer_upload_threshold_$which = $what");
}

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
sub request {
    my $len = shift || 0;
    my @cmds = @_;

    my $curpos = 0;
    my $remain = $len;

    my $hdr = "POST /status HTTP/1.0\r\nContent-length: $len\r\n\r\n";
    my $sock = IO::Socket::INET->new( PeerAddr => "127.0.0.1:$port" )
        or return undef;
    my $rv = syswrite($sock, $hdr);
    die unless $rv == length($hdr);

    my $res = undef;  # no response yet

    foreach my $cmd (@cmds) {
        my $writelen;

        if ($cmd =~ /^write:(\d+)/) {
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

        if ($writelen) {
            die "Too long" if $writelen > $remain;
            my $buf = "x" x $writelen;
            my $rv = syswrite($sock, $hdr);
            die "wrote $rv ($!), not $len" unless $rv == $writelen;
            $remain -= $rv;
            next unless $cmd eq "finish";
        }

        if ($cmd eq "finish") {
            $res = resp_from_sock($sock);
            next;
        }

        if (ref $cmd eq "CODE") {
            $cmd->($res);
            next;
        }

        die "Invalid command: $cmd\n";
    }
}

sub pid_of_resp {
    my $resp = shift;
    return 0 unless $resp && $resp->content =~ /^pid = (\d+)$/m;
    return $1;
}

1;
