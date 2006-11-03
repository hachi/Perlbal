######################################################################
# TCP listener on a given port
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005-2006, Six Apart, Ltd.


package Perlbal::TCPListener;
use strict;
use warnings;
no  warnings qw(deprecated);

use base "Perlbal::Socket";
use fields qw(service hostport);
use Socket qw(IPPROTO_TCP SOL_SOCKET SO_SNDBUF);

# TCPListener
sub new {
    my ($class, $hostport, $service, $opts) = @_;
    $opts ||= {};

    my $sockclass = $opts->{ssl} ? "IO::Socket::SSL" : "IO::Socket::INET";
    my $sock = eval {
        $sockclass->new(
                        LocalAddr => $hostport,
                        Proto => IPPROTO_TCP,
                        Listen => 1024,
                        ReuseAddr => 1,
                        ($opts->{ssl} ? %{$opts->{ssl}} : ()),
                        );
    };

    return Perlbal::error("Error creating listening socket: " . ($@ || $!))
        unless $sock;

    if ($^O eq 'MSWin32') {
        # On Windows, we have to do this a bit differently.
        # IO::Socket should really do this for us, but whatever.
        my $do = 1;
        ioctl($sock, 0x8004667E, \$do) or return Perlbal::error("Unable to make listener on $hostport non-blocking: $!");
    }
    else {
        # IO::Socket::INET's Blocking => 0 just doesn't seem to work
        # on lots of perls.  who knows why.
        IO::Handle::blocking($sock, 0) or return Perlbal::error("Unable to make listener on $hostport non-blocking: $!");
    }

    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    $self->{hostport} = $hostport;
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# TCPListener: accepts a new client connection
sub event_read {
    my Perlbal::TCPListener $self = shift;

    # accept as many connections as we can
    while (my ($psock, $peeraddr) = $self->{sock}->accept) {
        my $service_role = $self->{service}->role;

        if (Perlbal::DEBUG >= 1) {
            my ($pport, $pipr) = Socket::sockaddr_in($peeraddr);
            my $pip = Socket::inet_ntoa($pipr);
            print "Got new conn: $psock ($pip:$pport) for $service_role\n";
        }

        IO::Handle::blocking($psock, 0);

        if (my $sndbuf = $self->{service}->{client_sndbuf_size}) {
            my $rv = setsockopt($psock, SOL_SOCKET, SO_SNDBUF, pack("L", $sndbuf));
        }

        if ($service_role eq "reverse_proxy") {
            Perlbal::ClientProxy->new($self->{service}, $psock);
        } elsif ($service_role eq "management") {
            Perlbal::ClientManage->new($self->{service}, $psock);
        } elsif ($service_role eq "web_server") {
            Perlbal::ClientHTTP->new($self->{service}, $psock);
        } elsif ($service_role eq "selector") {
            # will be cast to a more specific class later...
            Perlbal::ClientHTTPBase->new($self->{service}, $psock, $self->{service});
        } elsif (my $creator = Perlbal::Service::get_role_creator($service_role)) {
            # was defined by a plugin, so we want to return one of these
            $creator->($self->{service}, $psock);
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
