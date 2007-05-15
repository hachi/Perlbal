#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More tests => 35;

my ($back_port) = start_webserver();

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
SET test.enable_reproxy = true
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
ok(manage("POOL a ADD 127.0.0.1:$back_port"), "backend port added");

my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$pb_port");
$wc->keepalive(1);
$wc->http_version('1.0');

# see if a single request works
my $resp = $wc->request('status');
ok($resp, 'status response ok');


# make a file on disk, verifying we can get it via disk/URL
my $phrase = "foo bar yo this is my content.\n";
my $file_content = $phrase x 1000;
open(F, ">$dir/foo.txt");
print F $file_content;
close(F);
ok(filecontent("$dir/foo.txt") eq $file_content, "file good via disk");

my $hc = Perlbal::Test::WebClient->new;
$hc->server("127.0.0.1:$webport");
$hc->keepalive(1);
$hc->http_version('1.0');
$resp = $hc->request('foo.txt');
ok($resp && $resp->content eq $file_content, 'file good via network');


# now request some ranges on it.....

foreach my $meth (qw(http rp_file rp_url)) {
    my $ua = {
        'http' => $hc,
        'rp_file' => $wc,
        'rp_url' => $wc,
    }->{$meth} || die;
    my $path = {
        'http' => "foo.txt",
        'rp_file' => "reproxy_file:$dir/foo.txt",
        'rp_url' => "reproxy_url:http://127.0.0.1:$webport/foo.txt",
    }->{$meth} || die;

    my $resp;
    my $range;
    my $send = sub {
        $range = shift;
        $resp = $ua->request({ headers => "Range: $range\r\n"}, $path);
    };

    my @aios = ("-");
    if ($meth eq "rp_file" || $meth eq "http") {
        @aios = qw(none ioaio);
    }

    foreach my $aio (@aios) {
        my $setaio = $aio eq "-" ? 1 : manage("SERVER aio_mode = $aio");
      SKIP: {
          skip "can't do AIO mode $aio", 6 unless $setaio;

          $send->("bytes=0-6");
          ok($resp && $resp->content eq "foo bar", "$meth/$aio: range $range");
          ok($resp->status_line =~ /^206/, "is partial") or diag(dump_res($resp));

          $send->("bytes=" . length($phrase) . "-");
          ok($resp && $resp->content eq ($phrase x 999), "$meth/$aio: range $range");
          ok($resp->status_line =~ /^206/, "is partial") or diag(dump_res($resp));

          $send->("bytes=" . length($file_content) . "-");
          ok($resp && $resp->status_line =~ /^416/, "$meth/$aio: can't satisify") or diag(dump_res($resp));

          $send->("bytes=5-1");
          ok($resp && $resp->status_line =~ /^416/, "$meth/$aio: can't satisify") or diag(dump_res($resp));
      }
    }

}


# try to reproxy to a list of URLs, where the first one is bogus, and last one is good
#ok_reproxy_url_list();

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
    ok($resp->content eq $file_content, "reproxy URL");
}

sub ok_status {
    my $resp = $wc->request('status');
    ok($resp && $resp->content =~ /\bpid\b/, 'status ok');
}

1;
