######################################################################
# UDP listener for Apache free/busy stats
######################################################################

package Perlbal::StatsListener;
use base "Perlbal::Socket";
use fields ('service',  # Perlbal::Service,
	    'pos',           # index in ring.  this index has an empty value in it
	                     # entries before it are good
	    'message_ring',  # arrayref of UDP messages, unparsed
	    'from_ring',     # arrayref of from addresses
	    'hostinfo',      # hashref of ip (4 bytes) -> [ $free, $active ] (or undef)
	    );

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

sub event_read {
    my Perlbal::StatsListener $self = shift;
    my $sock = $self->{sock};

    my $ring_size = 30;   # FIXME: arbitrary (but rewrite-balancer uses 10)

    while (my $from = $sock->recv($self->{message_ring}[$self->{pos}], 1024)) {
	$self->{from_ring}[$self->{pos}] = $from;
	$self->{pos} = 0 if ++$self->{pos} == $ring_size;

	# new message from host $from, so clear its cached data
	$hostinfo{$from} = undef if exists $hostinfo{$from};
    }
}

sub get_endpoint {
    my Perlbal::StatsListener $self = shift;

    # FIXME: implement
    return ();
}

sub set_hosts {
    my Perlbal::StatsListener $self = shift;
    my @hosts = @_;

    # clear the known hosts
    $self->{hostinfo} = {};

    # make each provided host known, but undef (meaning
    # its ring data hasn't been parsed)
    foreach my $dq (@hosts) {
	# converted dotted quad to packed format
	my $pd = Socket::inet_aton($dq);
	$self->{hostinfo}{$pd} = undef;
    }
}

sub event_err { }
sub event_hup { }

1;

__END__

    print "Ring pos: $self->{pos}\n";

    for (my $i=0; $i<$ring_size; $i++) {
	my $msg = $self->{message_ring}[$i];
	my $from = $self->{from_ring}[$i];
	next unless $from;

	$msg =~ s/\n/ /g;
	my ($port, $iaddr) = Socket::sockaddr_in($from);
	$iaddr = Socket::inet_ntoa($iaddr);
	print "$i: ($msg) from=$iaddr\n";
    }

}

