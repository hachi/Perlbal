######################################################################
# Service class
######################################################################

package Perlbal::Service;
use strict;

use Perlbal::BackendHTTP;

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
            'nodefile.checking',  # boolean; if true AIO is stating the file for us
            'sendstats.listen',        # what IP/port the stats listener runs on
            'sendstats.listen.socket', # Perlbal::StatsListener object
            'docroot',            # document root for webserver role
            'dirindexing',        # bool: direcotry indexing?  (for webserver role)  not async.
            'listener',
            'waiting_clients',         # arrayref of clients waiting for backendhttp conns
            'waiting_clients_highpri', # arrayref of high-priority clients waiting for backendhttp conns
            'waiting_client_count',    # number of clients waiting for backendds
            'waiting_client_map'  ,    # map of clientproxy fd -> 1 (if they're waiting for a conn)
            'pending_connects',        # hashref of "ip:port" -> $time (only one pending connect to backend at a time)
            'pending_connect_count',   # number of outstanding backend connects
            'high_priority_cookie',          # cookie name to check if client can 'cut in line' and get backends faster
            'high_priority_cookie_contents', # aforementioned cookie value must contain this substring
            'node_used',               # hashref of "ip:port" -> use count
            'connect_ahead',           # scalar: number of spare backends to connect to in advance all the time
            'backend_persist_cache',   # scalar: max number of persistent backends to hold onto while no clients
            'bored_backends',          # arrayref of backends we've already connected to, but haven't got clients
            'persist_client',  # bool: persistent connections for clients
            'persist_backend', # bool: persistent connections for backends
            'verify_backend',  # bool: get attention of backend before giving it clients (using OPTIONS)
            'max_backend_uses',  # max requests to send per kept-alive backend (default 0 = unlimited)
            );

sub new {
    my Perlbal::Service $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($name) = @_;

    $self->{name} = $name;
    $self->{enabled} = 0;
    $self->{listen} = "";
    $self->{persist_client} = 0;
    $self->{persist_backend} = 0;
    $self->{verify_backend} = 0;
    $self->{max_backend_uses} = 0;
    $self->{backend_persist_cache} = 2;

    $self->{nodes} = [];   # no configured nodes

    # track pending connects to backend
    $self->{pending_connects} = {};
    $self->{pending_connect_count} = 0;
    $self->{bored_backends} = [];
    $self->{connect_ahead} = 0;

    # waiting clients
    $self->{waiting_clients} = [];
    $self->{waiting_clients_highpri} = [];
    $self->{waiting_client_count} = 0;

    return $self;
}

# returns string of balance method
sub balance_method {
    my Perlbal::Service $self = shift;
    my $methods = {
        &BM_SENDSTATS => "sendstats",
        &BM_ROUNDROBIN => "round_robin",
        &BM_RANDOM => "random",
    };
    return $methods->{$self->{balance_method}} || $self->{balance_method};
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
    return 1 if $self->{'nodefile.checking'};

    $self->{'nodefile.checking'} = 1;
    Linux::AIO::aio_stat($self->{nodefile}, sub {
        return $self->{'nodefile.checking'} = 0
            unless -e _;

        my $mod = (stat(_))[9];
        return $self->{'nodefile.checking'} = 0
            if $mod == $self->{'nodefile.lastmod'};

        # construct a filehandle (we only have a descriptor here)
        open NODEFILE, $self->{nodefile}
            or return $self->{'nodefile.checking'} = 0;

        # prepare for adding nodes
        $self->{'nodefile.lastmod'} = $mod;
        $self->{nodes} = [];

        # now parse contents
        while (<NODEFILE>) {
            s/\#.*//;
            if (/(\d+\.\d+\.\d+\.\d+)(?::(\d+))?/) {
                my ($ip, $port) = ($1, $2);
                push @{$self->{nodes}}, [ $ip, $port || 80 ];
            }
        }
        close NODEFILE;

        # setup things using new data
        $self->{node_count} = scalar @{$self->{nodes}};
        $self->populate_sendstats_hosts;
        return $self->{'nodefile.checking'} = 0;
    });

    return 1;
}

# called by ClientProxy when it dies.
sub note_client_close {
    my Perlbal::Service $self;
    my Perlbal::ClientProxy $cp;
    ($self, $cp) = @_;

    if (delete $self->{waiting_client_map}{$cp->{fd}}) {
        $self->{waiting_client_count}--;
    }
}

sub mark_node_used {
    my Perlbal::Service $self = shift;
    my $hostport = shift;
    $self->{node_used}{$hostport}++;
}

sub get_client {
    my Perlbal::Service $self = shift;

    my $ret = sub {
        my Perlbal::ClientProxy $cp = shift;
        $self->{waiting_client_count}--;
        delete $self->{waiting_client_map}{$cp->{fd}};

        # before we return, start another round of connections
        $self->spawn_backends;

        return $cp;
    };

    # find a high-priority client, or a regular one
    my Perlbal::ClientProxy $cp;
    while ($cp = shift @{$self->{waiting_clients_highpri}}) {
        my $backlog = scalar @{$self->{waiting_clients}};
        if (Perlbal::DEBUG >= 2) {
            print "Got from fast queue, in front of $backlog others\n";
        }
        return $ret->($cp) if ! $cp->{closed};
    }
    while ($cp = shift @{$self->{waiting_clients}}) {
        if (Perlbal::DEBUG >= 2) {
            print "Backend requesting client, got normal = $cp->{fd}.\n" unless $cp->{closed};
        }
        return $ret->($cp) if ! $cp->{closed};
    }

    return undef;
}

# called by backend connection after it becomes writable
sub register_boredom {
    my Perlbal::Service $self;
    my Perlbal::BackendHTTP $be;
    ($self, $be) = @_;

    # note that this backend is no longer pending a connect,
    # if we thought it was before.  but not if it's a persistent
    # connection asking to be re-used.
    unless ($be->{use_count}) {
        if ($self->{pending_connects}{$be->{ipport}}) {
            $self->{pending_connects}{$be->{ipport}} = undef;
            $self->{pending_connect_count}--;
        }
    }

    my Perlbal::ClientProxy $cp = $self->get_client;
    if ($cp) {
        if ($be->assign_client($cp)) {
            return;
        } else {
            # don't want to lose client, so we (unfortunately)
            # stick it at the end of the waiting queue.
            # fortunately, assign_client shouldn't ever fail.
            $self->request_backend_connection($cp);
        }
    }

    # don't hang onto more bored, persistent connections than
    # has been configured for connect-ahead
    if ($be->{use_count}) {
        my $current_bored = scalar @{$self->{bored_backends}};
        if ($current_bored >= $self->{backend_persist_cache}) {
            $be->close;
            return;
        }
    }

    # put backends which are known to be bound to processes
    # and not to TCP stacks at the beginning where they'll
    # be used first
    if ($be->{has_attention}) {
        unshift @{$self->{bored_backends}}, $be;
    } else {
        push @{$self->{bored_backends}}, $be;
    }
}

sub note_bad_backend_connect {
    my Perlbal::Service $self;
    my ($ip, $port);
    ($self, $ip, $port) = @_;

    my $ipport = "$ip:$port";
    my $was_pending = $self->{pending_connects}{$ipport};
    if ($was_pending) {
        $self->{pending_connects}{$ipport} = undef;
        $self->{pending_connect_count}--;
    }

    # FIXME: do something interesting (tell load balancer about dead host,
    # and fire up a new connection, if warranted)

    # makes a new connection, if needed
    $self->spawn_backends;
}

sub request_backend_connection {
    my Perlbal::Service $self;
    my Perlbal::ClientProxy $cp;
    ($self, $cp) = @_;

    # before we even consider spawning backends, let's see if we have
    # some bored (pre-connected) backends that'd take this client
    my Perlbal::BackendHTTP $be;
    my $now = time;
    while ($be = shift @{$self->{bored_backends}}) {
        next if $be->{closed};

        # don't use connect-ahead connections when we haven't
        # verified we have their attention
        if (! $be->{has_attention} && $be->{create_time} < $now - 5) {
            $be->close("too_old_bored");
            next;
        }

        # don't use keep-alive connections if we know the server's
        # just about to kill the connection for being idle
        if ($be->{disconnect_at} && $now + 2 > $be->{disconnect_at}) {
            $be->close("too_close_disconnect");
            next;
        }

        # give the backend this client
        if ($be->assign_client($cp)) {
            # and make some extra bored backends, if configured as such
            $self->spawn_backends;
            return;
        }
    }

    my $hi_pri = 0;  # by default, low priority

    # is there a defined high-priority cookie?
    if (my $cname = $self->{high_priority_cookie}) {
        # decide what priority class this request is in
        my $hd = $cp->{req_headers};
        my %cookie;
        foreach (split(/;\s+/, $hd->header("Cookie") || '')) {
            next unless ($_ =~ /(.*)=(.*)/);
            $cookie{_durl($1)} = _durl($2);
        }
        my $hicookie = $cookie{$cname} || "";
        $hi_pri = index($hicookie, $self->{high_priority_cookie_contents}) != -1;

    }

    if ($hi_pri) {
        push @{$self->{waiting_clients_highpri}}, $cp;
    } else {
        push @{$self->{waiting_clients}}, $cp;
    }

    $self->{waiting_client_count}++;
    $self->{waiting_client_map}{$cp->{fd}} = 1;

    $self->spawn_backends;
}

# sees if it should spawn some backend connections
sub spawn_backends {
    my Perlbal::Service $self = shift;

    # now start a connection to a host

    # keep track of the sum of existing_bored + bored_created
    my $backends_created = scalar(@{$self->{bored_backends}}) + $self->{pending_connect_count};
    my $backends_needed = $self->{waiting_client_count} + $self->{connect_ahead};
    my $to_create = $backends_needed - $backends_created;

    # can't create more than this, assuming one pending connect per node
    my $max_creatable = $self->{node_count} - $self->{pending_connect_count};
    $to_create = $max_creatable if $to_create > $max_creatable;

    # cap number of attempted connects at once
    $to_create = 10 if $to_create > 10;

    my $now = time;

    while ($to_create > 0) {
        $to_create--;
        my ($ip, $port) = $self->get_backend_endpoint;
        unless ($ip) {
            print "No backend IP.\n";
            # FIXME: register desperate flag, so load-balancer module can callback when it has a node
            return;
        }
        if (my Perlbal::BackendHTTP $be = $self->{pending_connects}{"$ip:$port"}) {
            my $age = $now - $be->{create_time};
            if ($age >= 5 && $be->{state} eq "connecting") {
                $be->close;
            } elsif ($age >= 60 && $be->{state} eq "verifying_backend") {
                # after 60 seconds of attempting to verify, we're probably already dead
                $be->close;
            } elsif (! $be->{closed}) {
                next;
            }

            # TEMP: should we clean our bookkeeping here?  we really
            # shouldn't get here.
            $self->{pending_connects}{"$ip:$port"} = undef;
            $self->{pending_connect_count}--;
        }

        if (my $be = Perlbal::BackendHTTP->new($self, $ip, $port)) {
            $self->{pending_connects}{"$ip:$port"} = $be;
            $self->{pending_connect_count}++;
        }
    }
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

        # close/reopen listening socket
        if ($val ne $self->{listen} && $self->{enabled}) {
            $self->disable(undef, "force");
            $self->{listen} = $val;
            $self->enable(undef);
        }

        return $set->();
    }

    my $bool = sub {
        my $val = shift;
        return 1 if $val =~ /^1|true|on|yes$/i;
        return 0 if $val =~ /^0|false|off|no$/i;
        return undef;
    };

    if ($key eq "persist_client" || $key eq "persist_backend" ||
        $key eq "verify_backend") {
        $val = $bool->($val);
        return $err->("Expecting boolean value for option '$key'")
            unless defined $val;
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

    if ($key eq "high_priority_cookie" || $key eq "high_priority_cookie_contents") {
        return $set->();
    }

    if ($key eq "connect_ahead") {
        return $err->("Expected integer value") unless $val =~ /^\d+$/;
        $set->();
        $self->spawn_backends if $self->{enabled};
        return 1;
    }

    if ($key eq "max_backend_uses" || $key eq "backend_persist_cache") {
        return $err->("Expected integer value") unless $val =~ /^\d+$/;
        return $set->();
    }

    if ($key eq "nodefile") {
        return $err->("File not found")
            unless -e $val;

        # force a reload
        $self->{'nodefile'} = $val;
        $self->{'nodefile.lastmod'} = 0;
        $self->{'nodefile.checking'} = 0;
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
        $out && $out->("ERROR: service $self->{name} is already enabled");
        return 0;
    }

    # create listening socket
    my $tl = Perlbal::TCPListener->new($self->{listen}, $self);
    unless ($tl) {
        $out && $out->("Can't start service '$self->{name}' on $self->{listen}: $Perlbal::last_error");
        return 0;
    }

    $self->{listener} = $tl;
    $self->{enabled} = 1;
    return 1;
}

# Service
sub disable {
    my Perlbal::Service $self;
    my ($out, $force);

    ($self, $out, $force) = @_;

    if (! $self->{enabled}) {
        $out && $out->("ERROR: service $self->{name} is already disabled");
        return 0;
    }
    if ($self->{role} eq "management" && ! $force) {
        $out && $out->("ERROR: can't disable management service");
        return 0;
    }

    # find listening socket
    my $tl = $self->{listener};
    $tl->close;
    $self->{listener} = undef;
    $self->{enabled} = 0;
    return 1;
}

sub stats_info
{
    my Perlbal::Service $self = shift;
    my $out = shift;
    my $now = time;

    $out->("SERVICE $self->{name}");
    $out->("     listening: $self->{listen}");
    $out->("          role: $self->{role}");
    if ($self->{role} eq "reverse_proxy" ||
        $self->{role} eq "web_server") {
        $out->("  pend clients: $self->{waiting_client_count}");
        $out->("  pend backend: $self->{pending_connect_count}");
        foreach my $ipport (sort keys %{$self->{pending_connects}}) {
            my $be = $self->{pending_connects}{$ipport};
            next unless $be;
            my $age = $now - $be->{create_time};
            $out->("   $ipport - " . ($be->{closed} ? "(closed)" : $be->{state}) . " - ${age}s");
        }
    }
    if ($self->{role} eq "reverse_proxy") {
        my $bored_count = scalar @{$self->{bored_backends}};
        $out->(" connect-ahead: $bored_count/$self->{connect_ahead}");
        $out->("balance method: " . $self->balance_method);
        $out->("         nodes:");
        foreach my $n (@{ $self->{nodes} }) {
            my $hostport = "$n->[0]:$n->[1]";
            $out->(sprintf("                %-21s %7d", $hostport, $self->{node_used}{$hostport} || 0));
        }
    } elsif ($self->{role} eq "web_server") {
        $out->("        docroot: $self->{docroot}");
    }

    
}

sub _durl
{
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}


1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
