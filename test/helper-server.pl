#!/usr/bin/perl
#

use strict;
use IO::Socket::INET;

my $sock = IO::Socket::INET->new(Listen    => 5,
                                 LocalAddr => 'localhost',
                                 LocalPort => 8012,
                                 Reuse     => 1,
                                 Proto     => 'tcp');
while (my $child = $sock->accept) {
    my $reqline = <$child>;
    next unless $reqline =~ /^(\S+)\s+(\S+)\s+HTTP\/(\d+\.\d+)\r?\n/;
    my ($meth, $uri, $ver) = ($1, $2, $3);
    my %header;
    my $line;
    while (($line = <$child>) =~ /\S/) {
        $line =~ s/\r?\n$//;
        print "Got line: $line";
        next unless $line =~ /^(\w+):\s*(.+)/;
        $header{$1} = $2;
        print "1 = $1, 2 = $2\n";
    }

    my %args;
    foreach (split(m!/!, $uri)) {
        my ($k, $v) = split /=/;
        $args{$k} = $v if $k;
    }
    print "Args: " . join(", ", %args) . "\n";

}

