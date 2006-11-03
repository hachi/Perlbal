######################################################################
# Listen for UDP upload status packets
#
# Copyright 2005-2006, Six Apart, Ltd.


package Perlbal::UploadListener;
use strict;
use warnings;
no  warnings qw(deprecated);

use base "Perlbal::Socket";
use fields qw(service hostport);

# TCPListener
sub new {
    my ($class, $hostport, $service) = @_;

    my $sock =
        IO::Socket::INET->new(
                              LocalAddr => $hostport,
                              Proto => "udp",
                              ReuseAddr => 1,
                              Blocking => 0,
                              );

    return Perlbal::error("Error creating listening socket: " . ($@ || $!))
        unless $sock;

    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    $self->{hostport} = $hostport;
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

my %status;
my @todelete;

sub get_status {
    my $ses = shift;
    return $status{$ses};
}

# TCPListener: accepts a new client connection
sub event_read {
    my Perlbal::TCPListener $self = shift;

    my $buf;
    $self->{sock}->recv($buf, 500);
    return unless $buf =~ /^UPLOAD:(\w{5,50}):(\d+):(\d+):(\d+):(\d+)$/;
    my ($ses, $done, $total, $starttime, $nowtime) = ($1, $2, $3, $4, $5);

    my $now = time();

    $status{$ses} = {
        done => $done,
        total => $total,
        starttime => $starttime,
        lasttouch => $now,
    };

    # keep a history of touched records, then we'll clean 'em
    # after 30 seconds.
    push @todelete, [$now, $ses];
    my $too_old = $now - 4;
    while (@todelete && $todelete[0][0] < $too_old) {
        my $rec = shift @todelete;
        my $to_kill = $rec->[1];
        if (my $krec = $status{$to_kill}) {
            my $last_touch = $krec->{lasttouch};
            delete $status{$to_kill} if $last_touch < $too_old;
        }
    }
}

sub as_string {
    my Perlbal::TCPListener $self = shift;
    my $ret = $self->SUPER::as_string;
    my Perlbal::Service $svc = $self->{service};
    $ret .= ": listening on $self->{hostport} for service '$svc->{name}'";
    return $ret;
}

sub as_string_html {
    my Perlbal::TCPListener $self = shift;
    my $ret = $self->SUPER::as_string_html;
    my Perlbal::Service $svc = $self->{service};
    $ret .= ": listening on $self->{hostport} for service <b>$svc->{name}</b>";
    return $ret;
}

sub die_gracefully {
    # die off so we stop waiting for new connections
    my $self = shift;
    $self->close('graceful_death');
}


1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
