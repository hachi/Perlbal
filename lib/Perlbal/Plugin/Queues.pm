###########################################################################
# simple queue length header inclusion plugin
###########################################################################

package Perlbal::Plugin::Queues;

use strict;
use warnings;
no  warnings qw(deprecated);

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    # more complicated statistics
    $svc->register_hook('Queues', 'backend_client_assigned', sub {
        my Perlbal::BackendHTTP $obj = shift;
        my Perlbal::HTTPHeaders $hds = $obj->{req_headers};
        my Perlbal::Service $svc = $obj->{service};
        return 0 unless defined $hds && defined $svc;

        # determine age of oldest (first in line)
        my $now = time;
        my Perlbal::ClientProxy $cp = $svc->{waiting_clients}->[0];
        my $age = defined $cp ? ($now - $cp->{last_request_time}) : 0;

        # now do the age of the high priority queue
        $cp = $svc->{waiting_clients_highpri}->[0];
        my $hpage = defined $cp ? ($now - $cp->{last_request_time}) : 0;

        # setup the queue length headers
        $hds->header('X-Queue-Count', scalar(@{$svc->{waiting_clients}}));
        $hds->header('X-Queue-Age', $age);
        $hds->header('X-HP-Queue-Count', scalar(@{$svc->{waiting_clients_highpri}}));
        $hds->header('X-HP-Queue-Age', $hpage);
        return 0;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    # clean up time
    $svc->unregister_hooks('Queues');
    return 1;
}

# we don't do anything in here
sub load { return 1; }
sub unload { return 1; }

1;
