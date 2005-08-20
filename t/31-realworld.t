#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More tests => 106;

# option setup
my $start_servers = 3; # web servers to start

# setup a few web servers that we can work with
my @web_ports = map { start_webserver() } 1..$start_servers;
@web_ports = grep { $_ > 0 } map { $_ += 0 } @web_ports;
ok(scalar(@web_ports) == $start_servers, 'web servers started');

# setup a simple perlbal that uses the above server
my $pb_port = new_port();
my $pb_ss_port = new_port();

my $buffer_dir = tempdir();

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
LOAD vhosts

CREATE SERVICE ss
   SET role = selector
   SET listen = 127.0.0.1:$pb_ss_port
   SET persist_client = on
   SET plugins = vhosts
   VHOST * = test
ENABLE ss

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

for my $dport ("regular", "selector") {
    $wc->server("127.0.0.1:" . ($dport eq "regular" ? $pb_port : $pb_ss_port));

    for my $type (qw(plain buffer_to_memory buffer_to_disk)) {

        if ($type eq "plain") {
            manage("SET test.buffer_backend_connect = 0") or die;
            manage("SET test.buffer_uploads = off") or die;
        } elsif ($type eq "buffer_to_memory") {
            manage("SET test.buffer_uploads = off") or die;
            ok(manage("SET test.buffer_backend_connect = 250000"), "turned on buffering to memory");
        } elsif ($type eq "buffer_to_disk") {
            ok(manage("SET test.buffer_uploads = on"), "turned on buffering to disk");
        }

        for my $extra_rn (0, 1) {
            for my $post_header_pause (0, 0.75) {
                for my $n (1..2) {
                    $ct++;
                    $resp = $wc->request({ extra_rn => $extra_rn,
                                           method   => "POST",
                                           content  => "foo=bar",
                                           post_header_pause => $post_header_pause }, 'status');
                    is(reqnum($resp), $ct+1, "$dport: type=$type, extra_rn=$extra_rn, pause=$post_header_pause, n=$n: good POST");
                    is($wc->reqdone, $ct, "persisted to perlbal");
                }
            }
        }
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
