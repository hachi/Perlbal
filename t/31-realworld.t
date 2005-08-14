#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More tests => 32;

my $buffer_dir = tempdir();

# option setup
my $start_servers = 3; # web servers to start

# setup a few web servers that we can work with
my @web_ports = map { start_webserver() } 1..$start_servers;
@web_ports = grep { $_ > 0 } map { $_ += 0 } @web_ports;
ok(scalar(@web_ports) == $start_servers, 'web servers started');

# setup a simple perlbal that uses the above server
my $pb_port = new_port();
my $conf = qq{
CREATE POOL a

CREATE SERVICE test
SET test.role = reverse_proxy
SET test.listen = 127.0.0.1:$pb_port
SET test.persist_client = 1
SET test.persist_backend = 1
SET test.pool = a
SET test.connect_ahead = 0

SET buffer_uploads_path = $buffer_dir
SET buffer_uploads = off
SET buffer_upload_threshold_size = 1

ENABLE test

};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

add_all();

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$pb_port");
$wc->keepalive(0);
$wc->http_version('1.0');
ok($wc, 'web client object created');

# see if a single request works
my $resp = $wc->request('status');
ok($resp, 'status response ok');
my $pid = pid_of_resp($resp);
ok($pid, 'web server functioning');
is($wc->reqdone, 0, "didn't persist to perlbal");

my $ct = 0;

# persisent is on, so let's do some more and see if they're counting up
$wc->keepalive(1);

for my $type (qw(plain buffer_to_memory buffer_to_disk)) {

    if ($type eq "buffer_to_memory") {
        ok(manage("SET test.buffer_backend_connect = 250000"), "turned on buffering to memory");
    } elsif ($type eq "buffer_to_disk") {
        ok(manage("SET test.buffer_uploads = on"), "turned on buffering to disk");
    }

    # now some extra \r\n POST
    for my $n (1..2) {
        $ct++;
        $resp = $wc->request({ extra_rn => 1, method => "POST", content => "foo=bar" }, 'status');
        is(reqnum($resp), $ct+1, "number $n/$type: did a POST with extra \r\n");
        is($wc->reqdone, $ct, "persist to perlbal");
    }

    # now with pauses between headers and body
    for my $n (1..2) {
        $ct++;
        $resp = $wc->request({ extra_rn => 1, method => "POST", content => "foo=bar", post_header_pause => 0.75 }, 'status');
        is(reqnum($resp), $ct+1, "number $n/$type+pause");
        is($wc->reqdone, $ct, "persist to perlbal");
    }
}

sub add_all {
    foreach (@web_ports) {
        manage("POOL a ADD 127.0.0.1:$_") or die;
    }
}

sub pid_of_resp {
    my $resp = shift;
    return 0 unless $resp && $resp->content =~ /^pid = (\d+)$/m;
    return $1;
}

sub subpid_of_resp {
    my $resp = shift;
    return 0 unless $resp && $resp->content =~ /^subpid = (\d+)$/m;
    return $1;
}

sub reqnum {
    my $resp = shift;
    return 0 unless $resp && $resp->content =~ /^reqnum = (\d+)$/m;
    return $1;
}

sub options {
    my $resp = shift;
    return undef unless $resp && $resp->content =~ /^options = (\d+)$/m;
    return $1;
}

1;
