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
            'bored_backends',          # arrayref of backends we've already connected to, but haven't got clients
            );

sub new {
    my Perlbal::Service $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($name) = @_;

    $self->{name} = $name;
    $self->{enabled} = 0;
    $self->{listen} = "";

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

    # note that this backend is no longer pending a connect
    $self->{pending_connect_count}--;
    $self->{pending_connects}{$be->{ipport}} = undef;

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

    push @{$self->{bored_backends}}, $be;
}

sub note_bad_backend_connect {
    my Perlbal::Service $self;
    my ($ip, $port);

    ($self, $ip, $port) = @_;

    $self->{pending_connects}{"$ip:$port"} = undef;
    $self->{pending_connect_count}--;

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
        if ($be->{create_time} < $now - 5) {
            $be->close("too_old_bored");
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
        my $hd = $cp->{headers};
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
    my $tries = 0;

    # keep track of the sum of existing_bored + bored_created
    my $backends_created = scalar(@{$self->{bored_backends}}) + $self->{pending_connect_count};
    my $backends_needed = $self->{waiting_client_count} + $self->{connect_ahead};
    my $to_create = $backends_needed - $backends_created;
    
    my $now = time;

    while ($tries++ < 5 && $to_create > 0) {
        my ($ip, $port) = $self->get_backend_endpoint;
        unless ($ip) {
            print "No backend IP.\n";
            # FIXME: register desperate flag, so load-balancer module can callback when it has a node
            return;
        }
        next if $self->{pending_connects}{"$ip:$port"};
        if (Perlbal::BackendHTTP->new($self, $ip, $port)) {
            $self->{pending_connects}{"$ip:$port"} = $now;
            $self->{pending_connect_count}++;
            $to_create--;
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

    $out->("SERVICE $self->{name}");
    $out->("     listening: $self->{listen}");
    $out->("          role: $self->{role}");
    if ($self->{role} eq "reverse_proxy" ||
        $self->{role} eq "web_server") {
        $out->("  pend clients: $self->{waiting_client_count}");
        $out->("  pend backend: $self->{pending_connect_count}");
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
