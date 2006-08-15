#!/usr/bin/perl

use strict;
use Perlbal::Test;

use Test::More tests => 20;
require HTTP::Request;

my $port = new_port();
my $dir = tempdir();

my $conf = qq{
SERVER aio_mode = none

CREATE SERVICE test
SET test.role = web_server
SET test.listen = 127.0.0.1:$port
SET test.docroot = $dir
SET test.dirindexing = 0
SET test.persist_client = 1
SET test.enable_concatenate_get = 1
ENABLE test
};

my $http = "http://127.0.0.1:$port";

my $msock = start_server($conf);
ok($msock, "manage sock");
my $ua = ua();
ok($ua, "ua");

sub set_disk {
    my ($relpath, $contents) = @_;
    open(F, ">$dir$relpath") or die "Couldn't open $dir$relpath: $!\n";
    print F $contents;
    close F;
}

our $last_res;
sub get {
    my $url = shift;
    my $req = HTTP::Request->new(GET => $url);
    my $res = $last_res = $ua->request($req);
    return $res->is_success ? $res->content : undef;
}

# write two files to disk
mkdir "$dir/foo";
mkdir "$dir/foo/bar";
my $chunk1 = "a" x 50 . "\n";
my $chunk2 = "b" x 50 . "\n";
set_disk("/foo/a.txt", $chunk1);
set_disk("/foo/b.txt", $chunk2);
set_disk("/foo/bar/a.txt", $chunk1);
set_disk("/foo/bar/b.txt", $chunk2);

# test trailing slash
is(get("${http}/foo??a.txt,b.txt"), undef, "need trailing slash");
is($last_res->code, 500, "got 500 without trailing slash");

# test bogus directory
is(get("${http}/bogus/??a.txt,b.txt"), undef, "bogus directory");
is($last_res->code, 404, "got 404 for bogus directory");

# test bogus file
is(get("${http}/foo/??a.txt,bogus.txt"), undef, "bogus file");
is($last_res->code, 404, "got 404 for bogus file");

is(get("${http}/foo/??a.txt,b.txt"), "$chunk1$chunk2", "basic concat works");
is(get("${http}/foo/??a.txt,bar/b.txt"), "$chunk1$chunk2", "concat w/ directory");
is(get("${http}/foo/??a.txt,a.txt"), "$chunk1$chunk1", "dup concat");

# test that if-modified-since 304 works and w/o a content-length
{
    my $req = HTTP::Request->new(GET => "${http}/foo/??a.txt,bar/b.txt");
    my $res = $ua->request($req);
    ok($res, "got response again");
    my $lastmod = $res->header("Last-Modified");
    like($lastmod, qr/\bGMT$/, "and it has a last modified");
    $req = HTTP::Request->new(GET => "${http}/foo/??a.txt,bar/b.txt");
    $req->header("If-Modified-Since" => $lastmod);

    my $ua_keep = LWP::UserAgent->new(keep_alive => 2);
    $res = $ua_keep->request($req);
    ok($res, "got response again");
    is($res->code, 304, "the response is a 304");
    like($res->header("Last-Modified"), qr/\bGMT$/, "and it has a last modified");
    ok(! $res->header("Content-Length"), "No content-length");
    like($res->header("Connection"), qr/\bkeep-alive\b/, "and it's keep-alive");
}

manage("SET test.enable_concatenate_get = 0");
is(get("${http}/foo/??a.txt,a.txt"), undef, "denied");
is($last_res->code, 403, "got 403");

1;
