###########################################################################
# plugin that makes some requests high priority.  this is very LiveJournal
# specific, as this makes requests to the client protocol be treated as
# high priority requests.
###########################################################################

package Perlbal::Plugin::Highpri;

use strict;
use warnings;

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    # create a compiled regexp for very frequent use later
    my $cr = qr{^/interface/(?:xmlrpc|flat)$};

    # more complicated statistics
    $svc->register_hook('Highpri', 'make_high_priority', sub {
        my Perlbal::ClientProxy $cp = shift;

        # check it against our compiled regexp
        return 1 if $cp->{req_headers}->{uri} =~ /$cr/;

        # doesn't fit, so return 0
        return 0;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    # clean up time
    $svc->unregister_hooks('Highpri');
    return 1;
}

# we don't do anything in here
sub load { return 1; }
sub unload { return 1; }

1;
