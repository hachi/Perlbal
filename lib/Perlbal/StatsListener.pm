######################################################################
# UDP listener for Apache free/busy stats
######################################################################

package Perlbal::StatsListener;
use base "Perlbal::Socket";
use fields qw(service pos message_ring from_ring);

# StatsListener
sub new {
    my $class = shift;

    my ($hostport, $service) = @_;

    my $sock = IO::Socket::INET->new(
                                     LocalAddr => $hostport,
                                     Proto => 'udp',
				     ReuseAddr => 1,
                                     Blocking => 0,
                                     );

    return Perlbal::error("Error creating listening socket: $!")
	unless $sock;
    $sock->sockopt(Socket::SO_BROADCAST, 1);
    $sock->blocking(0);

    my $self = fields::new($class);
    $self->SUPER::new($sock);       # init base fields

    $self->{service} = $service;
    $self->{pos} = 0;
    $self->{message_ring} = [];
    $self->{from_ring} = [];

    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# StatsListener
sub event_read {
    my $self = shift;
    my $sock = $self->{sock};

    my $ring_size = 30;   # FIXME: arbitrary

    while (my $from = $sock->recv($self->{message_ring}[$self->{pos}], 1024)) {
	$self->{from_ring}[$self->{pos}] = $from;
	$self->{pos} = 0 if ++$self->{pos} == $ring_size;
    }

    return;

    print "Ring pos: $self->{pos}\n";

    for (my $i=0; $i<$ring_size; $i++) {
	my $msg = $self->{message_ring}[$i];
	my $from = $self->{from_ring}[$i];
	next unless $from;

	$msg =~ s/\n/ /g;
	my ($port, $iaddr) = Socket::sockaddr_in($from);
	$iaddr = Socket::inet_ntoa($iaddr);
	#print "$i: ($msg) from=$iaddr\n";
    }

}

# StatsListener
sub event_err { }
sub event_hup { }

1;
