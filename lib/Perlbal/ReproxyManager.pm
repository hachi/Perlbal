# HTTP connection to non-pool backend nodes (probably fast event-based webservers)
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005, Six Apart, Ltd.
#

package Perlbal::ReproxyManager;
use strict;
use warnings;
no  warnings qw(deprecated);

# class storage to store 'host:ip' => $service objects, for making
# reproxies use a service that you can then track
our $ReproxySelf;
our %ReproxyConnecting; # ( host:ip => $backend ); keeps track of outstanding connections to backend that
                        # are in the connecting state
our %ReproxyBored;      # ( host:ip => [ $backend, ... ] ); list of our bored backends
our %ReproxyQueues;     # ( host:ip => [ $clientproxy, ... ] ); queued up requests for this backend
our %ReproxyBackends;   # ( host:ip => [ $backend, ... ] ); array of backends we have connected
our %ReproxyMax;        # ( host:ip => int ); maximum number of connections to have open at any one time
our $ReproxyGlobalMax;  # int; the global cap used if no per-host cap is specified
our $NoSpawn = 0;       # bool; when set, spawn_backend immediately returns without running
our $LastCleanup = 0;   # int; time we last ran our cleanup logic (FIXME: temp hack)

Perlbal::track_var("rep_connecting", \%ReproxyConnecting);
Perlbal::track_var("rep_bored",      \%ReproxyBored);
Perlbal::track_var("rep_queues",     \%ReproxyQueues);
Perlbal::track_var("rep_backends",   \%ReproxyBackends);

# singleton new function; returns us if we exist, else creates us
sub get {
    return $ReproxySelf if $ReproxySelf;

    # doesn't exist, so create it and return it
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $ReproxySelf = $self;
}

# given (clientproxy, primary_res_hdrs), initiate proceedings to process a
# request for a reproxy resource
sub do_reproxy {
    my Perlbal::ReproxyManager $self = Perlbal::ReproxyManager->get; # singleton
    my Perlbal::ClientProxy $cp = $_[0];
    return undef unless $self && $cp;

    # get data we use
    my $datref = $cp->{reproxy_uris}->[0];
    my $ipport = "$datref->[0]:$datref->[1]";
    push @{$ReproxyQueues{$ipport} ||= []}, $cp;

    # see if we should do cleanup (FIXME: temp hack)
    my $now = time();
    if ($LastCleanup < $now - 5) {
        # remove closed backends from our array. this is O(n) but n is small
        # and we're paranoid that just keeping a count would get corrupt over
        # time.  also removes the backends that have clients that are closed.
        @{$ReproxyBackends{$ipport}} = grep {
            ! $_->{closed} && (! $_->{client} || ! $_->{client}->{closed})
        } @{$ReproxyBackends{$ipport}};

        $LastCleanup = $now;
    }

    # now start a new backend
    $self->spawn_backend($ipport);
    return 1;
}

# part of the reportto interface; this is called when a backend is unable to establish
# a connection with a backend.  we simply try the next uri.
sub note_bad_backend_connect {
    my Perlbal::ReproxyManager $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # decrement counts and undef connecting backend
    $ReproxyConnecting{$be->{ipport}} = undef;

    # if nobody waiting, doesn't matter if we couldn't get to this backend
    return unless @{$ReproxyQueues{$be->{ipport}} || []};

    # if we still have some connected backends then ignore this bad connection attempt
    return if scalar @{$ReproxyBackends{$be->{ipport}} || []};

    # at this point, we have no connected backends, and our connecting one failed
    # so we want to tell all of the waiting clients to try their next uri, because
    # this host is down.
    while (my Perlbal::ClientProxy $cp = shift @{$ReproxyQueues{$be->{ipport}}}) {
        $cp->try_next_uri;
    }
    return 1;
}

# called by a backend when it's ready for a request
sub register_boredom {
    my Perlbal::ReproxyManager $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # if this backend was connecting
    my $ipport = $be->{ipport};
    if ($ReproxyConnecting{$ipport} && $ReproxyConnecting{$ipport} == $be) {
        $ReproxyConnecting{$ipport} = undef;
        $ReproxyBackends{$ipport} ||= [];
        push @{$ReproxyBackends{$ipport}}, $be;
    }

    # sometimes a backend is closed but it tries to register with us anyway... ignore it
    # but since this might have been our only one, spawn another
    if ($be->{closed}) {
        $self->spawn_backend($ipport);
        return;
    }

    # find some clients to use
    while (my Perlbal::ClientProxy $cp = shift @{$ReproxyQueues{$ipport} || []}) {
        # safety checks
        next if $cp->{closed};

        # give backend to client
        $cp->use_reproxy_backend($be);
        return;
    }

    # no clients if we get here, so push onto bored backend list
    push @{$ReproxyBored{$ipport} ||= []}, $be;

    # clean up the front of our list if we can (see docs above)
    if (my Perlbal::BackendHTTP $bbe = $ReproxyBored{$ipport}->[0]) {
        if ($bbe->{alive_time} < time() - 5) {
            $NoSpawn = 1;
            $bbe->close('have_newer_bored');
            shift @{$ReproxyBored{$ipport}};
            $NoSpawn = 0;
        }
    }
    return 0;
}

# backend closed, decrease counts, etc
sub note_backend_close {
    my Perlbal::ReproxyManager $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # remove closed backends from our array. this is O(n) but n is small
    # and we're paranoid that just keeping a count would get corrupt over
    # time.
    @{$ReproxyBackends{$be->{ipport}}} = grep {
        ! $_->{closed}
    } @{$ReproxyBackends{$be->{ipport}}};

    # spawn more if needed
    $self->spawn_backend($be->{ipport});
}

sub spawn_backend {
    return if $NoSpawn;

    my Perlbal::ReproxyManager $self = $_[0];
    my $ipport = $_[1];

    # if we're already connecting, we don't want to spawn another one
    if (my Perlbal::BackendHTTP $be = $ReproxyConnecting{$ipport}) {
        # see if this one is too old?
        if ($be->{create_time} < (time() - 5)) { # older than 5 seconds?
            $self->note_bad_backend_connect($be);
            $be->close("connection_timeout");

            # we return here instead of spawning because closing the backend calls
            # note_backend_close which will call spawn_backend again, and at that
            # point we won't have a pending connection and can spawn
            return;
        } else {
            # don't spawn more if we're already connecting
            return;
        }
    }

    # if nobody waiting, don't spawn extra connections
    return unless @{$ReproxyQueues{$ipport} || []};

    # don't spawn if we have a bored one already
    while (my Perlbal::BackendHTTP $bbe = pop @{$ReproxyBored{$ipport} || []}) {

        # don't use keep-alive connections if we know the server's
        # just about to kill the connection for being idle
        my $now = time();
        if ($bbe->{disconnect_at} && $now + 2 > $bbe->{disconnect_at} ||
            $bbe->{alive_time} < $now - 5)
        {
            $NoSpawn = 1;
            $bbe->close("too_close_disconnect");
            $NoSpawn = 0;
            next;
        }

        # it's good, give it to someone
        $self->register_boredom($bbe);
        return;
    }

    # see if we have too many already?
    my $max = $ReproxyMax{$ipport} || $ReproxyGlobalMax || 0;
    my $count = scalar @{$ReproxyBackends{$ipport} || []};
    return if $max && ($count >= $max);

    # start one connecting and enqueue
    my $be = Perlbal::BackendHTTP->new(undef, split(/:/, $ipport), { reportto => $self })
        or return 0;
    $ReproxyConnecting{$ipport} = $be;
}

sub backend_response_received {
    my Perlbal::ReproxyManager $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];
    my Perlbal::ClientProxy $cp = $be->{client};

    # if no client, close backend and return 1
    unless ($cp) {
        $be->close("lost_client");
        return 1;
    }

    # pass on to client
    return $cp->backend_response_received($be);
}

sub dump_state {
    my $out = shift;
    return unless $out;

    # spits out what we have connecting
    while (my ($hostip, $dat) = each %ReproxyConnecting) {
        $out->("connecting $hostip 1") if defined $dat;
    }
    while (my ($hostip, $dat) = each %ReproxyBored) {
        $out->("bored $hostip " . scalar(@$dat));
    }
    while (my ($hostip, $dat) = each %ReproxyQueues) {
        $out->("clients_queued $hostip " . scalar(@$dat));
    }
    while (my ($hostip, $dat) = each %ReproxyBackends) {
        $out->("backends $hostip " . scalar(@$dat));
        foreach my $be (@$dat) {
            $out->("... " . $be->as_string);
        }
    }
    while (my ($hostip, $dat) = each %ReproxyMax) {
        $out->("SERVER max_reproxy_connections($hostip) = $dat");
    }
    $out->("SERVER max_reproxy_connections = " . ($ReproxyGlobalMax || 0));
    $out->('.');
}

1;
