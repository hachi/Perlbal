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
SET buffer_upload_size = 250000
ENABLE test
};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

ok(! buffer_file_exists(), "no files in buffer directory");

# setup data
my $data = 'x' x 1_000_000;
my ($curpos, $clen) = (0, 0);

# disable all of it
set_srt(undef, undef, undef);

# post our data, should not create buffer file
my $resp = quick_request(100_000);
ok(pid_of_resp($resp), "posting works");
ok(! buffer_file_exists(), "no files in buffer, good");

# try writing 400k of a 500k file, and set the buffer size to be "anything
# larger than 400k"
set_srt(400_000, undef, undef);
my $req = request(500_000);
do_write($req, 400_000);
ok(buffer_file_exists(), "files in buffer, good"); # should have buffer file by now
do_finish();
$resp = get_response();
ok(pid_of_resp($resp), "posting works"); # and request finished ok?



sub set_srt {
    my ($size, $rate, $time) = @_;

    # if they don't provide a value, basically 'disable' it -- set it
    # to such a value that none of our tests (should!) trigger it
    set_threshold('size', $size || 100_000_000);   # never = 100MB
    set_threshold('rate', $rate || 1);             # never = slower than 1 byte/sec
    set_threshold('time', $time || 60 * 60 * 24);  # never = longer than 1 day
}

sub set_threshold {
    my ($which, $what) = @_;
    manage("SET buffer_upload_threshold_$which = $what");
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

sub quick_request {
    my $sock = request(shift)
        or return undef;
    do_finish($sock);
    return get_response($sock);
}

sub request {
    my $len = shift || 0;
    $curpos = 0;
    $clen = $len;

    my $hdr = "POST /status HTTP/1.0\r\nContent-length: $len\r\n\r\n";
    my $sock = IO::Socket::INET->new( PeerAddr => "127.0.0.1:$port" )
        or return undef;
    print $sock $hdr;

    return $sock;
}

sub do_write {
    my $sock = shift;
    my $bytes = shift || 0;
    return unless $sock && $bytes;

    my $left = $clen - $curpos;
    $bytes = $left if $bytes > $left;

    print $sock substr($data, $curpos, $bytes);
    $curpos += $bytes;
    print STDERR "printed $bytes bytes, now at $curpos\n";
}

sub do_finish {
    my $sock = shift;
    do_write($sock, $clen - $curpos);
}

sub get_response {
    my $sock = shift;
    return resp_from_sock($sock);
}

sub pid_of_resp {
    my $resp = shift;
    return 0 unless $resp && $resp->content =~ /^pid = (\d+)$/m;
    return $1;
}

1;
