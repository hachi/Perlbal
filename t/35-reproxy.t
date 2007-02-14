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
my $webport = new_port();
my $dir = tempdir();
my $deadport = new_port();

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
SET test.enable_reproxy = 1
SET test.reproxy_cache_maxsize = 150
ENABLE test

CREATE SERVICE ws
SET ws.role = web_server
SET ws.listen = 127.0.0.1:$webport
SET ws.docroot = $dir
SET ws.dirindexing = 0
SET ws.persist_client = 1
ENABLE ws

};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

add_all();

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$pb_port");
$wc->keepalive(1);
$wc->http_version('1.0');

# see if a single request works
my $resp = $wc->request('status');
ok($resp, 'status response ok');

# make a file on disk, verifying we can get it via disk/URL
my $file_content = "foo bar yo this is my content.\n" x 1000;
open(F, ">$dir/foo.txt");
print F $file_content;
close(F);
ok(filecontent("$dir/foo.txt") eq $file_content, "file good via disk");
{
    my $wc2 = Perlbal::Test::WebClient->new;
    $wc2->server("127.0.0.1:$webport");
    $wc2->keepalive(1);
    $wc2->http_version('1.0');
    $resp = $wc2->request('foo.txt');
    ok($resp && $resp->content eq $file_content, 'file good via network');
}

# try to get that file, via internal file redirect
ok_reproxy_file();
ok_reproxy_file();
ok($wc->reqdone >= 2, "2 on same conn");

# reproxy URL support
ok_reproxy_url();
ok_reproxy_url();
ok($wc->reqdone >= 4, "4 on same conn");

# reproxy URL support, w/ 204s from backend
ok_reproxy_url_204();
ok_reproxy_url_204();

# reproxy cache support
{
    my $sig_counter = 0;
    local $SIG{USR1} = sub  { $sig_counter++ };

    is($sig_counter, 0, "Prior to first hit, counter should be zero.");
    ok_reproxy_url_cached("One");
    is($sig_counter, 1, "First hit to populate the cache.");
    ok_reproxy_url_cached("Two");
    is($sig_counter, 1, "Second hit should be cached.");
    sleep 2;
    is($sig_counter, 1, "Prior to third hit, counter should still be 1.");
    ok_reproxy_url_cached("Three");
    is($sig_counter, 2, "Third hit isn't cached, now 2.");
    ok_reproxy_url_cached("Four");
    is($sig_counter, 2, "Forth hit should be cached again, still 2.");
}

# back and forth every combo
#  FROM / TO:  status  file  url
#  status        X      X    X
#  file          X      X    X
#  url           X      X    X
foreach_aio {
    my $mode = shift;

    ok_status();
    ok_status();
    ok_reproxy_file();
    ok_reproxy_url();
    ok_status();
    ok_reproxy_url();
    ok_reproxy_url();
    ok_reproxy_file();
    ok_reproxy_file();
    ok_reproxy_url();
    ok_reproxy_file();
    ok_status();
    ok($wc->reqdone >= 12, "AIO mode $mode: 9 transitions");
};

# try to reproxy to a list of URLs, where the first one is bogus, and last one is good
ok_reproxy_url_list();

# responses to HEAD requests should not have a body
{
    $wc->keepalive(0);
    my $resp = $wc->request({
        method => "HEAD",
    }, "reproxy_url:http://127.0.0.1:$webport/foo.txt");
    ok($resp && $resp->content eq '', "no response body when req method is HEAD");
    $wc->keepalive(1);
}


sub ok_reproxy_url_cached {
    my $resp = $wc->request("reproxy_url_cached:1:http://127.0.0.1:$webport/foo.txt");
    ok($resp && $resp->content eq $file_content, "reproxy with cache: $_[0]");
}

sub ok_reproxy_url_list {
    my $resp = $wc->request("reproxy_url_multi:$deadport:$webport:/foo.txt");
    ok($resp->content eq $file_content, "reproxy URL w/ dead one first");
}

sub ok_reproxy_file {
    my $resp = $wc->request("reproxy_file:$dir/foo.txt");
    ok($resp && $resp->content eq $file_content, "reproxy file");
}

sub ok_reproxy_url {
    my $resp = $wc->request("reproxy_url:http://127.0.0.1:$webport/foo.txt");
    ok($resp->content eq $file_content, "reproxy URL") or diag(dump_res($resp));
    is($resp->code, 200, "response code is 200");
}

sub ok_reproxy_url_204 {
    my $resp = $wc->request("reproxy_url204:http://127.0.0.1:$webport/foo.txt");
    ok($resp->content eq $file_content, "reproxy URL") or diag(dump_res($resp));
    is($resp->code, 200, "204 response code is 200");
}

sub ok_status {
    my $resp = $wc->request('status');
    ok($resp && $resp->content =~ /\bpid\b/, 'status ok');
}

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



1;
