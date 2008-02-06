#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More tests => 38;

# option setup
my $start_servers = 2; # web servers to start

# setup a few web servers that we can work with
my @web_ports = map { start_webserver() } 1..$start_servers;
@web_ports = grep { $_ > 0 } map { $_ += 0 } @web_ports;
ok(scalar(@web_ports) == $start_servers, 'web servers started');

# setup a simple perlbal that uses the above server
my $dir = tempdir();
my $pb_port = new_port();

my $conf = qq{
LOAD vhosts
CREATE POOL a

CREATE SERVICE ss
  SET ss.listen = 127.0.0.1:$pb_port
  SET ss.role = selector
  SET ss.plugins = vhosts
  SET ss.persist_client = on

  VHOST ss proxy         = pr
  VHOST ss webserver     = ws
  VHOST ss *.webserver   = ws
  VHOST ss manage        = mgmt
ENABLE ss

CREATE SERVICE pr
  SET pr.role = reverse_proxy
  SET pr.persist_client = 1
  SET pr.persist_backend = 1
  SET pr.pool = a
  SET pr.connect_ahead = 0
ENABLE pr

CREATE SERVICE ws
  SET ws.role = web_server
  SET ws.docroot = $dir
  SET ws.dirindexing = 0
  SET ws.persist_client = 1
  SET ws.enable_put = 1
  SET ws.enable_delete = 1
ENABLE ws

};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

foreach (@web_ports) {
    manage("POOL a ADD 127.0.0.1:$_") or die;
}

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$pb_port");
$wc->keepalive(1);
$wc->http_version('1.0');

my $resp;
# see if a single request works
okay_status();
is($wc->reqdone, 1, "one done");

# put a file
my $file_content = "foo bar yo this is my content.\n" x 1000;

$resp = $wc->request({
    method => "PUT",
    content => $file_content,
    host => "webserver",
}, 'foo.txt');
ok($resp && $resp->code =~ /^2\d\d$/, "Good PUT");
is($wc->reqdone, 2, "two done");

# see if it made it
ok(filecontent("$dir/foo.txt") eq $file_content, "file good via disk");
okay_network();
is($wc->reqdone, 3, "three done");

# try a post
my $blob = "x bar yo yo yeah\r\n\r\n" x 5000;
my $bloblen = length $blob;

$resp = $wc->request({
    method => "POST",
    content => $blob,
    host => "proxy",
}, 'status');
ok($resp && $resp->content =~ /^method = POST$/m && $resp->content =~ /^length = $bloblen$/m, "proxy post");
is($wc->reqdone, 4, "four done");
okay_network();
is($wc->reqdone, 5, "five done");
okay_status();
is($wc->reqdone, 6, "six done");

# test that persist_client is based on the selector service, not the selected service
ok(manage("SET pr.persist_client = 0"), "pr.persist_client off");
okay_status();
is($wc->reqdone, 7, "seven done");
okay_status();
is($wc->reqdone, 8, "eight done");
ok(manage("SET ss.persist_client = 0"), "ss.persist_client off");
okay_status();
is($wc->reqdone, 0, "zero done");
ok(manage("SET ss.persist_client = 1"), "ss.persist_client on");
okay_status();
is($wc->reqdone, 1, "one done");
ok(manage("SET pr.persist_client = 1"), "pr.persist_client on");


# test the vhost matching
$resp = $wc->request({ host => "foo.proxy" }, 'status');
ok($resp && $resp->code =~ /^[45]/, "foo.proxy - bad");

$resp = $wc->request({ host => "foo.webserver" }, 'foo.txt');
ok($resp && $resp->code =~ /^2/, "foo.webserver - good") or diag(dump_res($resp));

$resp = $wc->request({ host => "foo.bar.webserver" }, 'foo.txt');
ok($resp && $resp->code =~ /^2/, "foo.bar.webserver - good");

$resp = $wc->request({ host => "bob" }, 'foo.txt');
ok($resp && $resp->code =~ /^[45]/, "bob - bad");

ok(manage("VHOST ss * = ws"), "enabling a default");

$resp = $wc->request({ host => "bob" }, 'foo.txt');
ok($resp && $resp->code =~ /^2/, "bob - good");

# test sending a request to a management service
$resp = $wc->request({ host => "manage" }, 'foo');
ok($resp && $resp->code =~ /^5/, "mapping to invalid service");


# test some management commands (quiet_failure makes the test framework not warn when
# these commands fail, since we expect them to)
ok(! manage("VHOST ss * ws", quiet_failure => 1), "missing equals");
ok(! manage("VHOST bad_service * = ws", quiet_failure => 1), "bad service");
ok(! manage("VHOST ss *!sdfsdf = ws", quiet_failure => 1), "bad hostname");
ok(! manage("VHOST ss * = ws!!sdf", quiet_failure => 1), "bad target");


sub okay_status {
    my $resp = $wc->request({ host => "proxy" }, 'status');
    ok($resp && $resp->content =~ /\bpid\b/, 'status response ok') or diag(dump_res($resp));
}

sub okay_network {
    my $resp = $wc->request({ host => "webserver" }, 'foo.txt');
    ok($resp && $resp->content eq $file_content, 'file good via network') or diag(dump_res($resp));
}

1;
