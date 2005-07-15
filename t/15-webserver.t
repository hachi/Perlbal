#!/usr/bin/perl

use strict;
use Perlbal::Test;

use File::Temp qw/tempdir/;
use Test::More 'no_plan';
require HTTP::Request;

my $port = 60001;
my $dir = tempdir( CLEANUP => 1 );

my $conf = qq{
SERVER aio_mode = none

CREATE SERVICE test
SET test.role = web_server
SET test.listen = 127.0.0.1:$port
SET test.docroot = $dir
SET test.dirindexing = 0
SET test.persist_client = 1
ENABLE test
};

my $msock = start_server($conf);
ok($msock, "manage sock");
my $ua = ua();
ok($ua, "ua");

my ($url, $disk_file, $contents);
sub set_path {
    my $path = shift;
    $url = "http://127.0.0.1:$port$path";
    $disk_file = "$dir$path";
}
sub set_contents {
    $contents = shift;
}
sub write_file {
    open(F, ">$disk_file") or die "Couldn't open $disk_file: $!\n";
    print F $contents;
    close F;
}

sub get {
    my $url = shift;
    my $req = HTTP::Request->new(GET => $url);
    my $res = $ua->request($req);
    return $res->is_success ? $res->content : undef;
}

# write a file to disk
mkdir "$dir/foo";
set_path("/foo/bar.txt");
set_contents("foo bar baz\n" x 1000);
write_file();
ok(filecontent($disk_file) eq $contents, "disk file verify");

# a simple get
ok(get($url) eq $contents, "GET request");

# 404 path
ok(! get("$url/404.txt"), "missing file");

# verify directory indexing is off
{
    my $dirurl = $url;
    $dirurl =~ s!/[^/]+?$!/!;
    my $diridx = get($dirurl);
    like($diridx, qr/Directory listing disabled/, "no dirlist");
    manage("SET test.dirindexing = 1");
    $diridx = get($dirurl);
    like($diridx, qr/bar\.txt/, "see dirlist");
}


1;
