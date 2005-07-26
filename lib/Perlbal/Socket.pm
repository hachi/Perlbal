# Base class for all socket types
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005, Six Apart, Ltd.

package Perlbal::Socket;
use strict;
use warnings;
use Perlbal::HTTPHeaders;

use Danga::Socket '1.25';
use base 'Danga::Socket';

use fields (
            'headers_string',  # headers as they're being read

            'req_headers',     # the final Perlbal::HTTPHeaders object inbound
            'res_headers',     # response headers outbound (Perlbal::HTTPHeaders object)

            'create_time',     # creation time
            'alive_time',      # last time noted alive
            'state',           # general purpose state; used by descendants.
            'do_die',          # if on, die and do no further requests

            'read_buf',
            'read_ahead',
            'read_size',
            );

use constant MAX_HTTP_HEADER_LENGTH => 102400;  # 100k, arbitrary

use constant TRACK_OBJECTS => 0;            # see @created_objects below
if (TRACK_OBJECTS) {
    use Scalar::Util qw(weaken isweak);
}

# time we last did a full connection sweep (O(n) .. lame)
# and closed idle connections.
our $last_cleanup = 0;
our %state_changes = (); # { "objref" => [ state, state, state, ... ] }
our $last_callbacks = 0; # time last ran callbacks
our $callbacks = []; # [ [ time, subref ], [ time, subref ], ... ]

# this one deserves its own section.  we keep track of every Perlbal::Socket object
# created if the TRACK_OBJECTS constant is on.  we use weakened references, though,
# so this list will hopefully contain mostly undefs.  users can ask for this list if
# they want to work with it via the get_created_objects_ref function.
our @created_objects; # ( $ref, $ref, $ref ... )
our $last_co_cleanup = 0; # clean the list every few seconds

sub get_statechange_ref {
    return \%state_changes;
}

sub get_created_objects_ref {
    return \@created_objects;
}

sub new {
    my Perlbal::Socket $self = shift;
    $self = fields::new( $self ) unless ref $self;

    Perlbal::objctor($self);

    $self->SUPER::new( @_ );
    $self->{headers_string} = '';
    $self->{state} = undef;
    $self->{do_die} = 0;

    $self->{read_buf} = [];        # scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client

    my $now = time;
    $self->{alive_time} = $self->{create_time} = $now;

    # see if it's time to do a cleanup
    # FIXME: constant time interval is lame.  on pressure/idle?
    if ($now - 15 > $last_cleanup) {
        $last_cleanup = $now;
        _do_cleanup();
    }

    # now put this item in the list of created objects
    if (TRACK_OBJECTS) {
        # clean the created objects list if necessary
        if ($last_co_cleanup < $now - 5) {
            # remove out undefs, because those are natural byproducts of weakening
            # references
            @created_objects = grep { $_ } @created_objects;

            # however, the grep turned our weak references back into strong ones, so
            # we have to reweaken them
            weaken($_) foreach @created_objects;

            # we've cleaned up at this point
            $last_co_cleanup = $now;
        }

        # now add this one to our cleaned list and weaken it
        push @created_objects, $self;
        weaken($created_objects[-1]);
    }

    return $self;
}

# FIXME: this doesn't scale in theory, but it might use less CPU in
# practice than using the Heap:: modules and manipulating the
# expirations all the time, thus doing things properly
# algorithmically.  and this is definitely less work, so it's worth
# a try.
sub _do_cleanup {
    my $sf = Perlbal::Socket->get_sock_ref;

    my $now = time;

    my %max_age;  # classname -> max age (0 means forever)
    my @to_close;
    while (my $k = each %$sf) {
        my Perlbal::Socket $v = $sf->{$k};
        my $ref = ref $v;
        unless (defined $max_age{$ref}) {
            $max_age{$ref} = $ref->max_idle_time || 0;
        }
        next unless $max_age{$ref};
        if ($v->{alive_time} < $now - $max_age{$ref}) {
            push @to_close, $v;
        }
    }

    $_->close("perlbal_timeout") foreach @to_close;
}

# CLASS METHOD: given a delay (in seconds) and a subref, this will call
# that subref in AT LEAST delay seconds. if the subref returns 0, the
# callback is discarded, but if it returns a positive number, the callback
# is pushed onto the callback stack to be called again in at least that
# many seconds.
sub register_callback {
    # adds a new callback to our list
    my ($delay, $subref) = @_;
    push @$callbacks, [ time + $delay, $subref ];
    return 1;
}

# CLASS METHOD: runs through the list of registered callbacks and executes
# any that need to be executed
# FIXME: this doesn't scale.  need a heap.
sub run_callbacks {
    my $now = time;
    return if $last_callbacks == $now;
    $last_callbacks = $now;

    my @destlist = ();
    foreach my $ref (@$callbacks) {
        # if their time is <= now...
        if ($ref->[0] <= $now) {
            # find out if they want to run again...
            my $rv = $ref->[1]->();

            # and if they do, push onto list...
            push @destlist, [ $rv + $now, $ref->[1] ]
                if defined $rv && $rv > 0;
        } else {
            # not time for this one, just shove it
            push @destlist, $ref;
        }
    }
    $callbacks = \@destlist;
}

# CLASS METHOD:
# default is for sockets to never time out.  classes
# can override.
sub max_idle_time { 0; }

# Socket: specific to HTTP socket types
sub read_headers {
    my Perlbal::Socket $self = shift;
    my $is_res = shift;

    $Perlbal::reqs++ unless $is_res;

    my $sock = $self->{sock};

    my $to_read = MAX_HTTP_HEADER_LENGTH - length($self->{headers_string});

    my $bref = $self->read($to_read);
    return $self->close('remote_closure') if ! defined $bref;  # client disconnected

    $self->{headers_string} .= $$bref;
    my $idx = index($self->{headers_string}, "\r\n\r\n");

    # can't find the header delimiter?
    if ($idx == -1) {
        $self->close('long_headers')
            if length($self->{headers_string}) >= MAX_HTTP_HEADER_LENGTH;
        return 0;
    }

    my $hstr = substr($self->{headers_string}, 0, $idx);
    print "HEADERS: [$hstr]\n" if Perlbal::DEBUG >= 2;

    my $extra = substr($self->{headers_string}, $idx+4);
    if (my $len = length($extra)) {
        push @{$self->{read_buf}}, \$extra;
        $self->{read_size} = $self->{read_ahead} = length($extra);
        print "post-header extra: $len bytes\n" if Perlbal::DEBUG >= 2;
    }

    unless (($is_res ? $self->{res_headers} : $self->{req_headers}) =
                Perlbal::HTTPHeaders->new(\$hstr, $is_res)) {
        # bogus headers?  close connection.
        return $self->close("parse_header_failure");
    }

    return $is_res ? $self->{res_headers} : $self->{req_headers};
}

### METHOD: drain_read_buf_to( $destination )
### Write read-buffered data (if any) from the receiving object to the
### I<destination> object.
sub drain_read_buf_to {
    my ($self, $dest) = @_;
    return unless $self->{read_ahead};

    while (my $bref = shift @{$self->{read_buf}}) {
        $dest->write($bref);
        $self->{read_ahead} -= length($$bref);
    }
}

### METHOD: die_gracefully()
### By default, if we're in persist_wait state, close.  Else, ignore.  Children
### can override if they want to do some other processing.
sub die_gracefully {
    my Perlbal::Socket $self = $_[0];
    if ($self->state eq 'persist_wait') {
        $self->close('graceful_shutdown');
    }
    $self->{do_die} = 1;
}

### METHOD: close()
### Set our state when we get closed.
sub close {
    my Perlbal::Socket $self = $_[0];
    $self->state('closed');
    return $self->SUPER::close($_[1]);
}

### METHOD: state()
### If you pass a parameter, sets the state, else returns it.
sub state {
    my Perlbal::Socket $self = shift;
    return $self->{state} unless @_;

    push @{$state_changes{"$self"} ||= []}, $_[0] if Perlbal::TRACK_STATES;
    return $self->{state} = $_[0];
}

sub read_request_headers  { read_headers(@_, 0); }
sub read_response_headers { read_headers(@_, 1); }

sub as_string_html {
    my Perlbal::Socket $self = shift;
    return $self->SUPER::as_string;
}

sub DESTROY {
    my Perlbal::Socket $self = shift;
    delete $state_changes{"$self"} if Perlbal::TRACK_STATES;
    Perlbal::objdtor($self);
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
