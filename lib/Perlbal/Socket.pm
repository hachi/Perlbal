######################################################################
# Base class for all socket types
######################################################################

package Perlbal::Socket;
use strict;
use IO::Epoll;

use fields qw(sock fd write_buf write_buf_offset write_buf_size
	      headers_string headers read_buf read_ahead read_size
	      closed event_watch);

use Errno qw( EINPROGRESS EWOULDBLOCK EISCONN EPIPE EAGAIN );
use Socket qw( IPPROTO_TCP );
use constant TCP_CORK => 3;    # FIXME: ghetto to hard-code this

use constant MAX_HTTP_HEADER_LENGTH => 102400;  # 100k, arbitrary

# keep track of active clients
our %sock;                             # fd (num) -> Perlbal::Socket object
our $epoll;

our @to_close;   # sockets to close when event loop is done

sub watched_sockets {
    return scalar keys %sock;
}

# Socket
sub new {
    my Perlbal::Socket $self = shift;
    $self = fields::new($self) unless ref $self;

    my $sock = shift;

    $self->{sock}        = $sock;
    my $fd = fileno($sock);
    $self->{fd}          = $fd;
    $self->{write_buf}      = [];
    $self->{write_buf_offset} = 0;
    $self->{write_buf_size} = 0;
    $self->{closed} = 0;

    unless ($epoll) {
	$epoll = epoll_create(1024);
	if ($epoll < 0) {
	    die "# fail: epoll_create: $!\n";
	}
    }

    $self->{event_watch} = EPOLLERR|EPOLLHUP;
    epoll_ctl($epoll, EPOLL_CTL_ADD, $fd, $self->{event_watch})
	and die "couldn't add epoll watch for $fd\n";

    $sock{$fd} = $self;
    return $self;
}

# Socket
sub tcp_cork {
    my Perlbal::Socket $self = shift;
    my $val = shift;

    setsockopt($self->{sock}, IPPROTO_TCP, TCP_CORK,
	       pack("l", $val ? 1 : 0))   || die "setsockopt: $!";
}

# Socket
sub watch_read {
    my Perlbal::Socket $self = shift;
    return if $self->{closed};

    my $val = shift;
    my $event = $self->{event_watch};
    $event &= ~EPOLLIN if ! $val;
    $event |=  EPOLLIN if   $val;
    if ($event != $self->{event_watch}) {
	epoll_ctl($epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
	    and print STDERR "couldn't modify epoll settings for $self->{fd} ($self) from $self->{event_watch} -> $event\n";
	$self->{event_watch} = $event;
    }
}

# Socket
sub watch_write {
    my Perlbal::Socket $self = shift;
    return if $self->{closed};

    my $val = shift;
    my $event = $self->{event_watch};
    $event &= ~EPOLLOUT if ! $val;
    $event |=  EPOLLOUT if   $val;
    if ($event != $self->{event_watch}) {
	epoll_ctl($epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
	    and print STDERR "couldn't modify epoll settings for $self->{fd} ($self) from $self->{event_watch} -> $event\n";
	$self->{event_watch} = $event;
    }
}


# Socket
sub close {
    my Perlbal::Socket $self = shift;
    my $reason = shift || "";

    my $fd = $self->{fd};
    my $sock = $self->{sock};
    $self->{closed} = 1;

    if (Perlbal::DEBUG >= 1) {
	my ($pkg, $filename, $line) = caller;
	print "Closing \#$fd due to $pkg/$filename/$line ($reason)\n";
    }

    if (epoll_ctl($epoll, EPOLL_CTL_DEL, $fd, $self->{event_watch}) == 0) {
	print "Client $fd disconnected.\n" if Perlbal::DEBUG >= 1;
    } else {
	print "epoll_ctl del failed on fd $fd\n" if Perlbal::DEBUG >= 1;
    }

    delete $sock{$fd};

    # defer closing the actual socket until the event loop is done
    # processing this round of events.  (otherwise we might reuse fds)
    push @to_close, $sock;

    return 0;
}

# Socket
sub sock {
    my Perlbal::Socket $self = shift;
    return $self->{sock};
}

# Socket
# $data may be scalar, scalar ref, code ref (to run when there), or undef just to kick-start
# returns 1 if writes all went through, or 0 if there are writes in queue
# (if it returns 1, caller should stop waiting for EPOLLOUT events)
sub write {
    my Perlbal::Socket $self;
    my $data;
    ($self, $data) = @_;

    my $bref;

    # just queue data if there's already a wait
    my $need_queue;

    if (defined $data) {
	$bref = ref $data ? $data : \$data;
	if ($self->{write_buf_size}) {
	    push @{$self->{write_buf}}, $bref;
	    $self->{write_buf_size} += ref $bref eq "SCALAR" ? length($$bref) : 1;
	    return 0;
	}

	# this flag says we're bypassing the queue system, knowing we're the
	# only outstanding write, and hoping we don't ever need to use it.
	# if so later, though, we'll need to queue
	$need_queue = 1;
    }

  WRITE:
    while (1) {
	return 1 unless $bref ||= $self->{write_buf}[0];

	my $len;
	eval {
	    $len = length($$bref); # this will die if $bref is a code ref, caught below
	};
	if ($@) {
	    if (ref $bref eq "CODE") {
		unless ($need_queue) {
		    $self->{write_buf_size}--;   # code refs are worth 1
		    shift @{$self->{write_buf}};
		}
		$bref->();
		undef $bref;
		next WRITE;
	    }
	    die "Write error: $@";
	}

	my $to_write = $len - $self->{write_buf_offset};
	my $written = syswrite($self->{sock}, $$bref, $to_write, $self->{write_buf_offset});

	if (! defined $written) {
	    if ($! == EPIPE) {
		return $self->close("EPIPE");
	    } elsif ($! == EAGAIN) {
		# since connection has stuff to write, it should now be
		# interested in pending writes:
		if ($need_queue) {
		    push @{$self->{write_buf}}, $bref;
		    $self->{write_buf_size} += $len;
		}
		$self->watch_write(1);
		return 0;
	    }
	    print STDERR "Closing connection ($self) due to write error: $!\n";
	    return $self->close("write_error");
	} elsif ($written != $to_write) {
	    print "Wrote PARTIAL $written bytes to $self->{fd}\n"
		if Perlbal::DEBUG >= 2;
	    if ($need_queue) {
		push @{$self->{write_buf}}, $bref;
		$self->{write_buf_size} += $len;
	    }
	    # since connection has stuff to write, it should now be
	    # interested in pending writes:
	    $self->{write_buf_offset} += $written;
	    $self->{write_buf_size} -= $written;
	    $self->watch_write(1);
	    return 0;
	} elsif ($written == $to_write) {
	    print "Wrote ALL $written bytes to $self->{fd} (nq=$need_queue)\n" 
		if Perlbal::DEBUG >= 2;
	    $self->{write_buf_offset} = 0;
	    
	    # this was our only write, so we can return immediately
	    # since we avoided incrementing the buffer size or
	    # putting it in the buffer.  we also know there
	    # can't be anything else to write.
	    return 1 if $need_queue;

	    $self->{write_buf_size} -= $written;
	    shift @{$self->{write_buf}};
	    undef $bref;
	    next WRITE;
	}
    }
}

# Socket
# returns scalar ref on read, or undef on connection closed.
sub read {
    my Perlbal::Socket $self = shift;
    my $bytes = shift;
    my $buf;
    my $sock = $self->{sock};

    my $res = sysread($sock, $buf, $bytes, 0);

    print "sysread = $res; \$! = $!\n" if Perlbal::DEBUG >= 2;

    if (! $res && $! != EWOULDBLOCK) {
	# catches 0=conn closed or undef=error
	print "Fd \#$self->{fd} read hit the end of the road.\n"
	    if Perlbal::DEBUG >= 2;
	return undef;
    }

    return \$buf;
}

# Socket
sub read_request_headers  { read_headers(@_, 0); }
sub read_response_headers { read_headers(@_, 1); }

# Socket: specific to HTTP socket types
sub read_headers {
    my Perlbal::Socket $self = shift;
    my $is_res = shift;

    my $sock = $self->{sock};

    my $to_read = MAX_HTTP_HEADER_LENGTH - length($self->{headers_string});

    my $bref = $self->read($to_read);
    return $self->close if ! defined $bref;  # client disconnected

    $self->{headers_string} .= $$bref;
    my $idx = index($self->{headers_string}, "\r\n\r\n");

    # can't find the header delimiter?
    if ($idx == -1) {
	$self->close('long_headers')
	    if length($self->{headers_string}) >= MAX_HTTP_HEADER_LENGTH;
	return 0;
    }

    $self->{headers} = substr($self->{headers_string}, 0, $idx);
    print "HEADERS: [$self->{headers}]\n" if Perlbal::DEBUG >= 2;

    my $extra = substr($self->{headers_string}, $idx+4);
    if (my $len = length($extra)) {
	push @{$self->{read_buf}}, \$extra;
	$self->{read_size} = $self->{read_ahead} = length($extra);
	print "post-header extra: $len bytes\n" if Perlbal::DEBUG >= 2;
    }

    unless ($self->{headers} = Perlbal::HTTPHeaders->new($self->{headers}, $is_res)) {
	# bogus headers?  close connection.
	return $self->close("parse_header_failure");
    }

    return $self->{headers};
}

# Socket
sub drain_read_buf_to {
    my ($self, $dest) = @_;
    return unless $self->{read_ahead};

    print "drain_read_buf_to ($self->{fd} -> $dest->{fd}): $self->{read_ahead} bytes\n"
	if Perlbal::DEBUG >= 2;
    while (my $bref = shift @{$self->{read_buf}}) {
	$dest->write($bref);
	$self->{read_ahead} -= length($$bref);
    }
}

# Socket
sub event_read  { die "Base class event_read called for $_[0]\n"; }
sub event_err   { die "Base class event_err called for $_[0]\n"; }
sub event_hup   { die "Base class event_hup called for $_[0]\n"; }
sub event_write {
    my $self = shift;
    $self->write(undef);
}

# Socket
sub wait_loop {

    # register Linux::AIO's pipe which gets written to from threads
    # doing blocking IO
    my $aio_fd = Linux::AIO::poll_fileno;
    epoll_ctl($epoll, EPOLL_CTL_ADD, $aio_fd, EPOLLIN);

    my $other_fds = {
	$aio_fd => sub {
	    # run any callbacks on async file IO operations
	    Linux::AIO::poll_cb();
	},
    };

    while (1) {
	# get up to 50 events, no timeout (-1)
	while (my $events = epoll_wait($epoll, 50, -1)) {
	  EVENT:
	    foreach my $ev (@$events) {
		# it's possible epoll_wait returned many events, including some at the end
		# that ones in the front triggered unregister-interest actions.  if we
		# can't find the %sock entry, it's because we're no longer interested
		# in that event.
		my Perlbal::Socket $pob = $sock{$ev->[0]};
		my $code;

		# if we didn't find a Perlbal::Socket subclass for that fd, try other
		# pseudo-registered (above) fds.
		if (! $pob) {
		    if (my $code = $other_fds->{$ev->[0]}) {
			$code->();
		    } 
		    next;
		}

		print "Event: fd=$ev->[0] (", ref($pob), "), state=$ev->[1] \@ " . time() . "\n"
		    if Perlbal::DEBUG >= 1;

		my $state = $ev->[1];
		$pob->event_read   if $state & EPOLLIN && ! $pob->{closed};
		$pob->event_write  if $state & EPOLLOUT && ! $pob->{closed};
		if ($state & (EPOLLERR|EPOLLHUP)) {
		    $pob->event_err    if $state & EPOLLERR && ! $pob->{closed};
		    $pob->event_hup    if $state & EPOLLHUP && ! $pob->{closed};
		}
	    }

	    # now we can close sockets that wanted to close during our event processing.
	    # (we didn't want to close them during the loop, as we didn't want fd numbers
	    #  being reused and confused during the event loop)
	    $_->close while ($_ = shift @to_close);
	}
	print STDERR "Event loop ending; restarting.\n";
    }
    exit 0;
}

1;
