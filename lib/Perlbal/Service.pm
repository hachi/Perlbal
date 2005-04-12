######################################################################
# Service class
######################################################################

package Perlbal::Service;
use strict;
use warnings;

use Net::Netmask;

use Perlbal::BackendHTTP;

use fields (
            'name',
            'enabled', # bool
            'role',    # currently 'reverse_proxy' or 'management'
            'listen',  # scalar: "$ip:$port"
            'pool',      # Perlbal::Pool that we're using to allocate nodes if we're in proxy mode
            'docroot',            # document root for webserver role
            'dirindexing',        # bool: direcotry indexing?  (for webserver role)  not async.
            'index_files',        # arrayref of filenames to try for index files
            'listener',
            'waiting_clients',         # arrayref of clients waiting for backendhttp conns
            'waiting_clients_highpri', # arrayref of high-priority clients waiting for backendhttp conns
            'waiting_client_count',    # number of clients waiting for backendds
            'waiting_client_map'  ,    # map of clientproxy fd -> 1 (if they're waiting for a conn)
            'pending_connects',        # hashref of "ip:port" -> $time (only one pending connect to backend at a time)
            'pending_connect_count',   # number of outstanding backend connects
            'high_priority_cookie',          # cookie name to check if client can 'cut in line' and get backends faster
            'high_priority_cookie_contents', # aforementioned cookie value must contain this substring
            'connect_ahead',           # scalar: number of spare backends to connect to in advance all the time
            'backend_persist_cache',   # scalar: max number of persistent backends to hold onto while no clients
            'bored_backends',          # arrayref of backends we've already connected to, but haven't got clients
            'persist_client',  # bool: persistent connections for clients
            'persist_backend', # bool: persistent connections for backends
            'verify_backend',  # bool: get attention of backend before giving it clients (using OPTIONS)
            'max_backend_uses',  # max requests to send per kept-alive backend (default 0 = unlimited)
            'hooks',    # hashref: hookname => [ [ plugin, ref ], [ plugin, ref ], ... ]
            'plugins',  # hashref: name => 1
            'plugin_order', # arrayref: name, name, name...
            'plugin_setters', # hashref: { plugin_name => { key_name => coderef } }
            'extra_config', # hashref: extra config options; name => values
            'enable_put', # bool: whether PUT is supported
            'max_put_size', # int: max size in bytes of a put file
            'min_put_directory', # int: number of directories required to exist at beginning of URIs in put
            'enable_delete', # bool: whether DELETE is supported
            'buffer_size', # int: specifies how much data a ClientProxy object should buffer from a backend
            'buffer_size_reproxy_url', # int: same as above but for backends that are reproxying for us
            'spawn_lock', # bool: if true, we're currently in spawn_backends
            'queue_relief_size', # int; number of outstanding standard priority
                                 # connections to activate pressure relief at
            'queue_relief_chance', # int:0-100; % chance to take a standard priority
                                   # request when we're in pressure relief mode
            'trusted_upstreams', # Net::Netmask object containing netmasks for trusted upstreams
            'always_trusted', # bool; if true, always trust upstreams
            'extra_headers', # { insert => [ [ header, value ], ... ], remove => [ header, header, ... ],
                             #   set => [ [ header, value ], ... ] }; used in header management interface
            'generation', # int; generation count so we can slough off backends from old pools
            'backend_no_spawn', # { "ip:port" => 1 }; if on, spawn_backends will ignore this ip:port combo
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
    $self->{generation} = 0;
    $self->{backend_no_spawn} = {};

    $self->{hooks} = {};
    $self->{plugins} = {};
    $self->{plugin_order} = [];

    $self->{enable_put} = 0;
    $self->{max_put_size} = 0; # 0 means no max size
    $self->{min_put_directory} = 0;
    $self->{enable_delete} = 0;

    # disable pressure relief by default
    $self->{queue_relief_size} = 0;
    $self->{queue_relief_chance} = 0;

    # set some default maximum buffer sizes
    $self->{buffer_size} = 256_000;
    $self->{buffer_size_reproxy_url} = 51_200;

    # track pending connects to backend
    $self->{pending_connects} = {};
    $self->{pending_connect_count} = 0;
    $self->{bored_backends} = [];
    $self->{connect_ahead} = 0;

    # waiting clients
    $self->{waiting_clients} = [];
    $self->{waiting_clients_highpri} = [];
    $self->{waiting_client_count} = 0;

    # directory handling
    $self->{dirindexing} = 0;
    $self->{index_files} = [ 'index.html' ];

    # don't have an object for this yet
    $self->{trusted_upstreams} = undef;
    $self->{always_trusted} = 0;

    # bare data structure for extra header info
    $self->{extra_headers} = { remove => [], insert => [] };

    return $self;
}

# run the hooks in a list one by one until one hook returns 1.  returns
# 1 or 0 depending on if any hooks handled the request.
sub run_hook {
    my Perlbal::Service $self = shift;
    my $hook = shift;
    if (defined (my $ref = $self->{hooks}->{$hook})) {
        # call all the hooks until one returns true
        foreach my $hookref (@$ref) {
            my $rval = $hookref->[1]->(@_);
            return 1 if defined $rval && $rval;
        }
    }
    return 0;
}

# run a bunch of hooks in this service, always returns undef.
sub run_hooks {
    my Perlbal::Service $self = shift;
    my $hook = shift;
    if (defined (my $ref = $self->{hooks}->{$hook})) {
        # call all the hooks
        $_->[1]->(@_) foreach @$ref;
    }
    return undef;
}

# define a hook for this service
sub register_hook {
    my Perlbal::Service $self = shift;
    my ($pclass, $hook, $ref) = @_;
    push @{$self->{hooks}->{$hook} ||= []}, [ $pclass, $ref ];
    return 1;
}

# remove hooks we have defined
sub unregister_hook {
    my Perlbal::Service $self = shift;
    my ($pclass, $hook) = @_;
    if (defined (my $refs = $self->{hooks}->{$hook})) {
        my @new;
        foreach my $ref (@$refs) {
            # fill @new with hooks that DON'T match
            push @new, $ref
                unless $ref->[0] eq $pclass;
        }
        $self->{hooks}->{$hook} = \@new;
        return 1;
    }
    return undef;
}

# remove all hooks of a certain class
sub unregister_hooks {
    my Perlbal::Service $self = shift;
    foreach my $hook (keys %{$self->{hooks}}) {
        # call unregister_hook with this hook name
        $self->unregister_hook($_[0], $hook);        
    }
}

# register a value setter for plugin configuration
sub register_setter {
    my Perlbal::Service $self = shift;
    my ($pclass, $key, $coderef) = @_;
    return unless $pclass && $key && $coderef;
    $self->{plugin_setters}->{lc $pclass}->{lc $key} = $coderef;
}

# remove a setter
sub unregister_setter {
    my Perlbal::Service $self = shift;
    my ($pclass, $key) = @_;
    return unless $pclass && $key;
    delete $self->{plugin_setters}->{lc $pclass}->{lc $key};
}

# remove a bunch of setters
sub unregister_setters {
    my Perlbal::Service $self = shift;
    my $pclass = shift;
    return unless $pclass;
    delete $self->{plugin_setters}->{lc $pclass};    
}

# take a backend we've created and mark it as pending if we do not
# have another pending backend connection in this slot
sub add_pending_connect {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;

    # error if we already have a pending connection for this ipport
    if (defined $self->{pending_connects}{$be->{ipport}}) {
        Perlbal::log('warning', "Warning: attempting to spawn backend connection that already existed.");

        # now dump a backtrace so we know how we got here
        my $depth = 0;
        while (my ($package, $filename, $line, $subroutine) = caller($depth++)) {
            Perlbal::log('warning', "          -- [$filename:$line] $package::$subroutine");
        }

        # we're done now, just return
        return;
    }

    # set this connection up in the pending connection list
    $self->{pending_connects}{$be->{ipport}} = $be;
    $self->{pending_connect_count}++;
}

# remove a backend connection from the pending connect list if and only
# if it is the actual connection contained in the list; prevent double
# decrementing on accident
sub clear_pending_connect {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    if (defined $self->{pending_connects}{$be->{ipport}} && defined $be &&
            $self->{pending_connects}{$be->{ipport}} == $be) {
        $self->{pending_connects}{$be->{ipport}} = undef;
        $self->{pending_connect_count}--;
    }
}

# called by BackendHTTP when it's closed by any means
sub note_backend_close {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    $self->clear_pending_connect($be);
    $self->spawn_backends;
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
    my Perlbal::Service $self = $_[0];
    $self->{pool}->mark_node_used($_[1]) if $self->{pool};
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

    # determine if we should jump straight to the high priority queue or
    # act as pressure relief on the standard queue
    my $hp_first = 1;
    if (($self->{queue_relief_size} > 0) &&
            (scalar(@{$self->{waiting_clients}}) >= $self->{queue_relief_size})) {
        # if we're below the chance level, take a standard queue item
        $hp_first = 0
            if rand(100) < $self->{queue_relief_chance};
    }

    # find a high-priority client, or a regular one
    my Perlbal::ClientProxy $cp;
    while ($hp_first && ($cp = shift @{$self->{waiting_clients_highpri}})) {
        if (Perlbal::DEBUG >= 2) {
            my $backlog = scalar @{$self->{waiting_clients}};
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

# given a backend, verify it's generation
sub verify_generation {
    my Perlbal::Service $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # fast cases: generation count matches, so we just return an 'okay!' flag
    return 1 if $self->{generation} == $be->generation;

    # if our current pool knows about this ip:port, then we can still use it
    if (defined $self->{pool}->node_used($be->ipport)) {
        # so we know this is good, in the future we just want to hit the fast case
        # and continue, so let's update the generation
        $be->generation($self->{generation});
        return 1;
    }

    # if we get here, the backend should be closed
    $be->close('invalid_generation');
    return 0;
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
        $self->clear_pending_connect($be);
    }

    # it is possible that this backend is part of a different pool that we're
    # no longer using... if that's the case, we want to close it
    return unless $self->verify_generation($be);

    # now try to fetch a client for it
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
            $be->close('too_many_bored');
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
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    my $retry_time = shift();

    # clear this pending connection
    $self->clear_pending_connect($be);

    # mark this host as dead for a while if we need to
    if (defined $retry_time && $retry_time > 0) {
        # we don't want other spawn_backends calls to retry
        $self->{backend_no_spawn}->{$be->{ipport}} = 1;

        # and now we set a callback to ensure we're kicked at the right time
        Perlbal::Socket::register_callback($retry_time, sub {
            delete $self->{backend_no_spawn}->{$be->{ipport}};
            $self->spawn_backends;
        });
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
    
    # now, call hook to see if this should be high priority
    $hi_pri = $self->run_hook('make_high_priority', $cp)
        unless $hi_pri; # only if it's not already
    $cp->{high_priority} = 1 if $hi_pri;

    # before we even consider spawning backends, let's see if we have
    # some bored (pre-connected) backends that'd take this client
    my Perlbal::BackendHTTP $be;
    my $now = time;
    while ($be = shift @{$self->{bored_backends}}) {
        next if $be->{closed};

        # now make sure that it's still in our pool, and if not, close it
        next unless $self->verify_generation($be);

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

    if ($hi_pri) {
        push @{$self->{waiting_clients_highpri}}, $cp;
    } else {
        push @{$self->{waiting_clients}}, $cp;
    }

    $self->{waiting_client_count}++;
    $self->{waiting_client_map}{$cp->{fd}} = 1;

    $self->spawn_backends;
}

# sees if it should spawn one or more backend connections
sub spawn_backends {
    my Perlbal::Service $self = shift;

    # to spawn we must have a pool
    return unless $self->{pool};

    # check our lock and set it if we can
    return if $self->{spawn_lock};
    $self->{spawn_lock} = 1;

    # sanity checks on our bookkeeping
    if ($self->{pending_connect_count} < 0) {
        Perlbal::log('crit', "Bogus: service $self->{name} has pending connect ".
                     "count of $self->{pending_connect_count}?!  Resetting.");
        $self->{pending_connect_count} = scalar
            map { $_ && ! $_->{closed} } values %{$self->{pending_connects}};
    }

    # keep track of the sum of existing_bored + bored_created
    my $backends_created = scalar(@{$self->{bored_backends}}) + $self->{pending_connect_count};
    my $backends_needed = $self->{waiting_client_count} + $self->{connect_ahead};
    my $to_create = $backends_needed - $backends_created;

    # can't create more than this, assuming one pending connect per node
    my $max_creatable = $self->{pool}->node_count - $self->{pending_connect_count};
    $to_create = $max_creatable if $to_create > $max_creatable;

    # cap number of attempted connects at once
    $to_create = 10 if $to_create > 10;

    my $now = time;

    while ($to_create > 0) {
        $to_create--;
        my ($ip, $port) = $self->{pool}->get_backend_endpoint;
        unless ($ip) {
            Perlbal::log('crit', "No backend IP for service $self->{name}");
            # FIXME: register desperate flag, so load-balancer module can callback when it has a node
            $self->{spawn_lock} = 0;
            return;
        }

        # handle retry timeouts so we don't spin
        next if $self->{backend_no_spawn}->{"$ip:$port"};

        # if it's pending, verify the pending one is still valid
        if (my Perlbal::BackendHTTP $be = $self->{pending_connects}{"$ip:$port"}) {
            my $age = $now - $be->{create_time};
            if ($age >= 5 && $be->{state} eq "connecting") {
                $be->close('connect_timeout');
            } elsif ($age >= 60 && $be->{state} eq "verifying_backend") {
                # after 60 seconds of attempting to verify, we're probably already dead
                $be->close('verify_timeout');
            } elsif (! $be->{closed}) {
                next;
            }
        }

        # now actually spawn a backend and add it to our pending list
        if (my $be = Perlbal::BackendHTTP->new($self, $ip, $port, { pool => $self->{pool},
                                                                    generation => $self->{generation} })) {
            $self->add_pending_connect($be);
        }
    }

    # clear our spawn lock
    $self->{spawn_lock} = 0;
}

# getter only
sub role {
    my Perlbal::Service $self = shift;
    return $self->{role};
}

# manage some header stuff
sub header_management {
    my Perlbal::Service $self = shift;

    my ($mode, $key, $val, $out) = @_;
    my $err = sub { $out->("ERROR: $_[0]"); return 0; };

    return $err->("no header provided") unless $key;
    return $err->("no value provided") unless $val || $mode eq 'remove';

    if ($mode eq 'insert') {
        push @{$self->{extra_headers}->{insert}}, [ $key, $val ];
    } elsif ($mode eq 'remove') {
        push @{$self->{extra_headers}->{remove}}, $key;
    } else {
        return $err->("invalid mode '$mode'");
    }
    return 1;
}

sub munge_headers {
    my Perlbal::Service $self = $_[0];
    my Perlbal::HTTPHeaders $hdrs = $_[1];

    # handle removals first
    foreach my $hdr (@{$self->{extra_headers}->{remove}}) {
        $hdrs->header($hdr, undef);
    }

    # and now insertions
    foreach my $hdr (@{$self->{extra_headers}->{insert}}) {
        $hdrs->header($hdr->[0], $hdr->[1]);
    }
}

# Service
sub set {
    my Perlbal::Service $self = shift;

    my ($key, $val, $out, $verbose) = @_;
    my $err = sub { $out->("ERROR: $_[0]");   return 0;       };
    my $ok  = sub { $out->("OK") if $verbose; return 1;       };
    my $set = sub { $self->{$key} = $val;     return $ok->(); };

    my $pool_set = sub {
        # if we don't have a pool, automatically create one named $NAME_pool
        unless ($self->{pool}) {
            # die if necessary
            die "ERROR: Attempt to vivify pool $self->{name}_pool but one or more pools\n" .
                "       have already been created manually.  Please set $key on a\n" .
                "       previously created pool.\n" unless $Perlbal::vivify_pools;

            # create the pool and ensure that vivify stays on
            Perlbal::run_manage_command("CREATE POOL $self->{name}_pool", $out);
            Perlbal::run_manage_command("SET $self->{name}.pool = $self->{name}_pool");
            $Perlbal::vivify_pools = 1;
        }

        # now we actually do the set
        warn "WARNING: '$key' set on service $self->{name} on auto-vivified pool.\n" .
             "         This behavior is obsolete.  This value should be set on a\n" .
             "         pool object and not on a service.\n" if $Perlbal::vivify_pools;
        return $err->("No pool defined for service") unless $self->{pool};
        return $self->{pool}->set($key, $val, $out, $verbose);
    };

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

    if ($key eq 'trusted_upstream_proxies') {
        if ($self->{trusted_upstreams} = Net::Netmask->new2($val)) {
            # set, all good
            return $ok->();
        } else {
            return $err->("Error defining trusted upstream proxies: " . Net::Netmask::errstr());
        }
    }

    if ($key eq 'always_trusted') {
        $val = $bool->($val);
        return $err->("Expecting boolean value for option '$key'")
            unless defined $val;
        return $set->();
    }

    if ($key eq 'enable_put' || $key eq 'enable_delete') {
        return $err->("This can only be used on web_server service")
            unless $self->{role} eq 'web_server';
        $val = $bool->($val);
        return $err->("Expecting boolean value for option '$key'.")
            unless defined $val;
        return $set->();
    }

    if ($key eq "persist_client" || $key eq "persist_backend" ||
        $key eq "verify_backend") {
        $val = $bool->($val);
        return $err->("Expecting boolean value for option '$key'")
            unless defined $val;
        return $set->();
    }

    # this is now handled by Perlbal::Pool, so we pass this set command on
    # through in case people try to use it on us like the old method.
    return $pool_set->()
        if $key eq 'balance_method' ||
           $key eq 'nodefile' ||
           $key =~ /^sendstats\./;
    if ($key eq "balance_method") {
        return $err->("Can only set balance method on a reverse_proxy service")
            unless $self->{role} eq "reverse_proxy";
    }

    if ($key eq "high_priority_cookie" || $key eq "high_priority_cookie_contents") {
        return $set->();
    }

    if ($key eq "connect_ahead") {
        return $err->("Expected integer value") unless $val =~ /^\d+$/;
        $set->();
        $self->spawn_backends if $self->{enabled};
        return $ok->();
    }

    if ($key eq "max_backend_uses" || $key eq "backend_persist_cache" ||
        $key eq "max_put_size" || $key eq "min_put_directory" ||
        $key eq "buffer_size" || $key eq "buffer_size_reproxy_url" ||
        $key eq "queue_relief_size") {
        return $err->("Expected integer value") unless $val =~ /^\d+$/;
        return $set->();
    }

    if ($key eq "queue_relief_chance") {
        return $err->("Expected integer value") unless $val =~ /^\d+$/;
        return $err->("Expected integer value between 0 and 100 inclusive")
            unless $val >= 0 && $val <= 100;
        return $set->();
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

    if ($key eq "index_files") {
        return $err->("Can only set index_files on a web_server service")
            unless $self->{role} eq "web_server";
        my @list = split(/[\s,]+/, $val);
        $self->{index_files} = \@list;
        return $ok->();
    }

    if ($key eq 'plugins') {
        # unload existing plugins
        foreach my $plugin (keys %{$self->{plugins}}) {
            eval "Perlbal::Plugin::$plugin->unregister(\$self);";
            return $err->($@) if $@;
        }
        
        # clear out loaded plugins and hooks
        $self->{hooks} = {};
        $self->{plugins} = {};
        $self->{plugin_order} = [];
        
        # load some plugins
        foreach my $plugin (split /[\s,]+/, $val) {
            next if $plugin eq 'none';

            # since we lowercase our input, uppercase the first character here
            my $fn = uc($1) . lc($2) if $plugin =~ /^(.)(.*)$/;
            next if $self->{plugins}->{$fn};
            unless ($Perlbal::plugins{$fn}) {
                $err->("Plugin $fn not loaded; not registered for $self->{name}.");
                next;
            }

            # now register it
            eval "Perlbal::Plugin::$fn->register(\$self);";
            $self->{plugins}->{$fn} = 1;
            push @{$self->{plugin_order}}, $fn;
            return $err->($@) if $@;
        }
        return $ok->();
    }

    if ($key =~ /^extra\.(.+)$/) {
        # set some extra configuration data data
        $self->{extra_config}->{$1} = $val;
        return $ok->();
    }

    if ($key eq 'pool') {
        my $pl = Perlbal->pool($val);
        return $err->("Pool '$val' not found") unless $pl;
        $self->{pool}->decrement_use_count if $self->{pool};
        $self->{pool} = $pl;
        $self->{pool}->increment_use_count;
        $self->{generation}++;
        return $ok->();
    }

    # see if it happens to be a plugin set command?
    if ($key =~ /^(.+)\.(.+)$/) {
        if (my $coderef = $self->{plugin_setters}->{$1}->{$2}) {
            return $coderef->($out, $2, $val);
        }
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
        $out && $out->("ERROR: Can't start service '$self->{name}' on $self->{listen}: $Perlbal::last_error");
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
        if ($self->{pool}) {
            $out->("          pool: " . $self->{pool}->name);
            $out->("balance method: " . $self->{pool}->balance_method);
            $out->("         nodes:");
            foreach my $n (@{ $self->{pool}->nodes }) {
                my $hostport = "$n->[0]:$n->[1]";
                $out->(sprintf("                %-21s %7d", $hostport, $self->{pool}->node_used($hostport) || 0));
            }
        }
    } elsif ($self->{role} eq "web_server") {
        $out->("        docroot: $self->{docroot}");
    }
}

# simple passthroughs to the run_hook mechanism.  part of the reportto interface.
sub backend_response_received {
    return $_[0]->run_hook('backend_response_received', $_[1]);
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
