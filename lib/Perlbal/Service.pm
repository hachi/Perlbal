######################################################################
# Service class
######################################################################

package Perlbal::Service;
use strict;

# how often to reload the nodefile
use constant NODEFILE_RELOAD_FREQ => 3;

use constant BM_SENDSTATS => 1;
use constant BM_ROUNDROBIN => 2;
use constant BM_RANDOM => 3;

use fields (
	    'name',
	    'enabled', # bool
	    'role',    # currently 'reverse_proxy' or 'management'
	    'listen',  # scalar: "$ip:$port"
	    'balance_method',  # BM_ constant from above
	    'nodefile',
	    'nodes',              # arrayref of [ip, port] values (port defaults to 80)
	    'node_count',         # number of nodes
	    'nodefile.lastmod',   # unix time nodefile was last modified
	    'nodefile.lastcheck', # unix time nodefile was last stated
	    'sendstats.listen',        # what IP/port the stats listener runs on
	    'sendstats.listen.socket', # Perlbal::StatsListener object
	    'docroot',            # document root for webserver role
	    'dirindexing',        # bool: direcotry indexing?  (for webserver role)  not async.
	    'listener'
	    );

sub new {
    my Perlbal::Service $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($name) = @_;

    $self->{name} = $name;
    $self->{enabled} = 0;
    $self->{nodes} = [];   # no configured nodes

    return $self;
}

sub populate_sendstats_hosts {
    my Perlbal::Service $self = shift;

    # tell the sendstats listener about the new list of valid
    # IPs to listen from
    if ($self->{balance_method} == BM_SENDSTATS) {
	my $ss = $self->{'sendstats.listen.socket'};
	$ss->set_hosts(map { $_->[0] } @{$self->{nodes}}) if $ss;
    }
}

sub load_nodefile {
    my Perlbal::Service $self = shift;

    return 0 unless $self->{'nodefile'};

    my $mod = (stat($self->{'nodefile'}))[9];
    return 1 if $mod == $self->{'nodefile.lastmod'};

    if (open (NF, $self->{nodefile})) {
	$self->{'nodefile.lastmod'} = $mod;
	$self->{nodes} = [];
	while (<NF>) {
	    s/\#.*//;
	    if (/(\d+\.\d+\.\d+\.\d+)(?::(\d+))?/) {
		my ($ip, $port) = ($1, $2);
		push @{$self->{nodes}}, [ $ip, $port || 80 ];
	    }
	}
	close NF;

	$self->{node_count} = scalar @{$self->{nodes}};
	$self->populate_sendstats_hosts;
    }
    return 1;
}

sub get_backend_endpoint {
    my Perlbal::Service $self = shift;

    my @endpoint;  # (IP,port)

    # re-load nodefile if necessary
    my $now = time;
    if ($now > $self->{'nodefile.lastcheck'} + NODEFILE_RELOAD_FREQ) {
	$self->{'nodefile.lastcheck'} = $now;
	$self->load_nodefile;
    }

    if ($self->{balance_method} == BM_SENDSTATS) {
	my $ss = $self->{'sendstats.listen.socket'};
	if ($ss && (@endpoint = $ss->get_endpoint)) {
	    return @endpoint;
	}
    }

    # no nodes?
    return () unless $self->{node_count};

    # pick one randomly
    return @{$self->{nodes}[int(rand($self->{node_count}))]};
}

# getter only
sub role {
    my Perlbal::Service $self = shift;
    return $self->{role};
}

# Service
sub set {
    my Perlbal::Service $self = shift;

    my ($key, $val, $out) = @_;
    my $err = sub { $out->("ERROR: $_[0]"); return 0; };
    my $set = sub { $self->{$key} = $val;   return 1; };

    if ($key eq "role") {
	return $err->("Unknown service role")
	    unless $val eq "reverse_proxy" || $val eq "management" || $val eq "web_server";
	return $set->();
    }

    if ($key eq "listen") {
	return $err->("Invalid host:port")
	    unless $val =~ m!^\d+\.\d+\.\d+\.\d+:\d+$!;
	return $set->();
    }

    if ($key eq "balance_method") {
	return $err->("Can only set balance method on a reverse_proxy service")
	    unless $self->{role} eq "reverse_proxy";
	$val = {
	    'sendstats' => BM_SENDSTATS,
	    'random' => BM_RANDOM,
	}->{$val};
	return $err->("Unknown balance method")
	    unless $val;
	return $set->();
    }

    if ($key eq "nodefile") {
	return $err->("File not found")
	    unless -e $val;

	# force a reload
	$self->{'nodefile'} = $val;
	$self->{'nodefile.lastmod'} = 0;
	$self->load_nodefile;
	$self->{'nodefile.lastcheck'} = time;

	return 1;
    }

    if ($key eq "docroot") {
	return $err->("Can only set docroot on a web_server service")
	    unless $self->{role} eq "web_server";
	$val =~ s!/$!!;
	return $err->("Directory not found")
	    unless $val && -d $val;
	return $set->();
    }

    if ($key eq "dirindexing") {
	return $err->("Can only set dirindexing on a web_server service")
	    unless $self->{role} eq "web_server";
	return $err->("Expected value 0 or 1")
	    unless $val eq '0' || $val eq '1';
	return $set->();
    }

    if ($key =~ /^sendstats\./) {
	return $err->("Can only set sendstats listening address on service with balancing method 'sendstats'")
	    unless $self->{balance_method} == BM_SENDSTATS;
	if ($key eq "sendstats.listen") {
	    return $err->("Invalid host:port")
		unless $val =~ m!^\d+\.\d+\.\d+\.\d+:\d+$!;

	    if (my $pbs = $self->{"sendstats.listen.socket"}) {
		$pbs->close;
	    }

	    unless ($self->{"sendstats.listen.socket"} =
		    Perlbal::StatsListener->new($val, $self)) {
		return $err->("Error creating stats listener: $Perlbal::last_error");
	    }

	    $self->populate_sendstats_hosts;
	}
	return $set->();
    }

    return $err->("Unknown attribute '$key'");
}

# Service
sub enable {
    my Perlbal::Service $self;
    my $out;
    ($self, $out) = @_;

    if ($self->{enabled}) {
	$out->("ERROR: service $self->{name} is already enabled");
	return 0;
    }

    # create listening socket
    my $tl = Perlbal::TCPListener->new($self->{listen}, $self);
    unless ($tl) {
	$out->("Can't start service '$self->{name}' on $self->{listen}: $Perlbal::last_error");
	return 0;
    }

    $self->{listener} = $tl;
    $self->{enabled} = 1;
    return 1;
}

# Service
sub disable {
    my Perlbal::Service $self;
    my $out;
    ($self, $out) = @_;

    if (! $self->{enabled}) {
	$out->("ERROR: service $self->{name} is already disabled");
	return 0;
    }
    if ($self->{role} eq "management") {
	$out->("ERROR: can't disable management service");
        return 0;
    }

    # find listening socket
    my $tl = $self->{listener};
    $tl->close;
    $self->{listener} = undef;
    $self->{enabled} = 0;
    return 1;
}

1;
