######################################################################
# HTTP Connection from a reverse proxy client.  GET/HEAD only.
#  most functionality is implemented in the base class.
######################################################################

package Perlbal::ClientHTTP;
use strict;
use base "Perlbal::ClientHTTPBase";
use HTTP::Date ();

use Errno qw( EPIPE );
use POSIX ();

sub event_read {
    my Perlbal::ClientHTTP $self = shift;

    # Because Perlbal's HTTP support is GET/HEAD-only, we never process
    # POST/PUT data in requests.  so if we've already got the headers,
    # there's nothing new of interest
    if ($self->{req_headers}) {
        $self->watch_read(0);
        return;
    }

    # try and get the headers, if they're all here
    my $hd = $self->read_request_headers;
    return unless $hd;

    # and once we have it, start serving
    $self->watch_read(0);
    return $self->_serve_request($hd);
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
