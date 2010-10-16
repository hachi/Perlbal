# Base class for SSL sockets.
#
# This is a simple class that extends Danga::Socket and contains an IO::Socket::SSL
# for the purpose of allowing non-blocking SSL in Perlbal.
#
# WARNING: this code will break IO::Socket::SSL if you use it in any plugins or
# have custom Perlbal modifications that use it.  you will run into issues.  This
# is because we override the close method to prevent premature closure of the socket,
# so you will end up with the socket not closing properly.
#
# Copyright 2007, Mark Smith <mark@plogs.net>.
#
# This file is licensed under the same terms as Perl itself.

package Perlbal::SocketSSL;

use strict;
use warnings;
no  warnings qw(deprecated);

use Danga::Socket 1.44;
use IO::Socket::SSL 0.98;
use Errno qw( EAGAIN );
use Perlbal::Socket;

use base 'Danga::Socket';
use fields qw( listener create_time alive_time);

# magic IO::Socket::SSL crap to make it play nice with us
{
    no strict 'refs';
    no warnings 'redefine';

    # replace IO::Socket::SSL::close with our own code...
    my $orig = *IO::Socket::SSL::close{CODE};
    *IO::Socket::SSL::close = sub {
        my $self = shift()
            or return IO::Socket::SSL::_invalid_object();

        # if we have args, close ourselves (second call!), else don't
        if (exists ${*$self}->{__close_args}) {
            $orig->($self, @{${*$self}->{__close_args}});
        } else {
            ${*$self}->{__close_args} = [ @_ ];
            if (exists ${*$self}->{_danga_socket}) {
                ${*$self}->{_danga_socket}->close('intercepted_ssl_close');
            }
        }
    };
}

Perlbal::Socket->set_socket_idle_handler('Perlbal::SocketSSL' => sub {
    my Perlbal::SocketSSL $v = shift;

    my $max_age = eval { $v->max_idle_time } || 0;
    return unless $max_age;

    # Attributes are in another class, don't violate object boundaries.
    $v->close("perlbal_timeout")
        if $v->{alive_time} < $Perlbal::tick_time - $max_age;
});

# called: CLASS->new( $sock, $tcplistener )
sub new {
    my Perlbal::SocketSSL $self = shift;
    $self = fields::new( $self ) unless ref $self;

    Perlbal::objctor($self);

    my ($sock, $listener) = @_;

    ${*$sock}->{_danga_socket} = $self;
    $self->{listener} = $listener;
    $self->{alive_time} = $self->{create_time} = time;

    $self->SUPER::new($sock);

    # TODO: would be good to have an overall timeout so that we can
    # kill sockets that are open and just sitting there.  "ssl_handshake_timeout"
    # or something like that...

    return $self;
}

# this is nonblocking, it attempts to setup SSL and if it can't then
# it returns whether it needs to read or write.  we then setup to wait
# for the event it indicates and then wait.  when that event fires, we
# call down again, and repeat the process until we have setup the
# SSL connection.
sub try_accept {
    my Perlbal::SocketSSL $self = shift;

    my $sock = $self->{sock}->accept_SSL;

    if (defined $sock) {
        # looks like we got it!  let's steal it from ourselves
        # so Danga::Socket gives up on it and we can send
        # it out to someone else.  (we discard the return value
        # as we already have it in $sock)
        #
        # of course, life isn't as simple as that.  we have to do
        # some trickery with the ordering here to ensure that we
        # don't setup the new class until after the Perlbal::SocketSSL
        # goes away according to Danga::Socket.
        # 
        # if we don't do it this way, we get nasty errors because
        # we (this object) still exists in the DescriptorMap of
        # Danga::Socket when the new Perlbal::ClientXX tries to
        # insert itself there.

        # removes us from the active polling, closes up shop, but
        # save our fd first!
        my $fd = $self->{fd};
        $self->steal_socket;

        # finish blowing us away
        my $ref = Danga::Socket->DescriptorMap();
        delete $ref->{$fd};

        # now stick the new one in
        my Perlbal::ClientHTTPBase $cb = $self->{listener}->class_new_socket($sock);
        $cb->{is_ssl} = 1;
        return;
    }

    # nope, let's see if we can continue the process
    if ($! == EAGAIN) {
        if ($SSL_ERROR == SSL_WANT_READ) {
            $self->watch_read(1);
        } elsif ($SSL_ERROR == SSL_WANT_WRITE) {
            $self->watch_write(1);
        } else {
            $self->close('invalid_ssl_state');
        }
    } else {
        $self->close('invalid_ssl_error');
    }
}

sub event_read {
    $_[0]->watch_read(0);
    $_[0]->{alive_time} = $Perlbal::tick_time;
    $_[0]->try_accept;
}

sub event_write {
    $_[0]->watch_write(0);
    $_[0]->{alive_time} = $Perlbal::tick_time;
    $_[0]->try_accept;
}

sub event_err {
    $_[0]->close('invalid_ssl_state');
}

# You can tuna-fish, but you can't tune a Perlbal::SocketSSL
sub max_idle_time {
    return 60;
}

1;
