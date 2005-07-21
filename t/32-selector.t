#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More 'no_plan';

# option setup
my $start_servers = 2; # web servers to start

# setup a few web servers that we can work with
my @web_ports = map { start_webserver() } 1..$start_servers;
@web_ports = grep { $_ > 0 } map { $_ += 0 } @web_ports;
ok(scalar(@web_ports) == $start_servers, 'web servers started');

# setup a simple perlbal that uses the above server
my $dir = tempdir();
my $pb_port = new_port();

print "pb_port: $pb_port\n";

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

# see if a single request works
my $resp = $wc->request({ host => "proxy" }, 'status');
ok($resp && $resp->content =~ /\bpid\b/, 'status response ok') or diag(dump_res($resp));

# put a file
my $file_content = "foo bar yo this is my content.\n" x 1000;

$resp = $wc->request({
    method => "PUT",
    content => $file_content,
    host => "webserver",
}, 'foo.txt');

# see if it made it
ok(filecontent("$dir/foo.txt") eq $file_content, "file good via disk");
$resp = $wc->request({ host => "webserver" }, 'foo.txt');
ok($resp && $resp->content eq $file_content, 'file good via network') or diag(dump_res($resp));


1;
