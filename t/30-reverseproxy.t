#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More 'no_plan';

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

# persisent is on, so let's do some more and see if they're counting up
$wc->keepalive(1);
$resp = $wc->request('status');
is(reqnum($resp), 2, "second request");
is($wc->reqdone, 1, "persist to perlbal");
$resp = $wc->request('status');
is(reqnum($resp), 3, "third request");
is($wc->reqdone, 2, "persist to perlbal again");

# turn persisent off and see that they're not going up
ok(manage("SET test.persist_backend = 0"), "persist backend off");

# do some request to get rid of that perlbal->backend connection (it's
# undefined whether disabling backend connections immediately
# disconnects them all or not)
$resp = $wc->request('status');  # dummy request
$resp = $wc->request('status');
is(reqnum($resp), 1, "first request");

# make a second webclient now to test multiple requests at once, and
# perlbal making multiple backend connections
ok(manage("SET test.persist_backend = 1"), "persist backend back on");

# testing that backend persistence works
$resp = $wc->request('status');
$pid = pid_of_resp($resp);
$resp = $wc->request('status');
ok($pid == pid_of_resp($resp), "used same backend");

# multiple parallel backends in operation
$resp = $wc->request("subreq:$pb_port");
$pid = pid_of_resp($resp);
my $subpid = subpid_of_resp($resp);
ok($subpid, "got subpid");
ok($subpid != $pid, "two different backends in use");

# making the web server suggest not to keep the connection alive, see if
# perlbal respects it
$resp = $wc->request('keepalive:0', 'status');
$pid = pid_of_resp($resp);
$resp = $wc->request('keepalive:0', 'status');
ok(pid_of_resp($resp) != $pid, "discarding keep-alive?");


sub add_all {
    foreach (@web_ports) {
        manage("POOL a ADD 127.0.0.1:$_") or die;
    }
}

sub remove_all {
    foreach (@web_ports) {
        manage("POOL a REMOVE 127.0.0.1:$_") or die;
    }
}

sub flush_pools {
    remove_all();
    add_all();
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

1;
