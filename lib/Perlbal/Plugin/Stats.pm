###########################################################################
# basic Perlbal statistics gatherer
###########################################################################

package Perlbal::Plugin::Stats;

use strict;
use warnings;
no  warnings qw(deprecated);

use Time::HiRes qw(gettimeofday tv_interval);

# setup our package variables
our %statobjs; # { svc_name => [ service, statobj ], svc_name => [ service, statobj ], ... }

# define all stats keys here
our @statkeys = qw( files_sent      files_reproxied
                    web_requests    proxy_requests
                    proxy_requests_highpri          );

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    # create a stats object
    my $sobj = Perlbal::Plugin::Stats::Storage->new();
    $statobjs{$svc->{name}} = [ $svc, $sobj ];

    # simple events we count are done here.  when the hook on the left side is called,
    # we simply increment the count of the stat ont he right side.
    my %simple = qw(
        start_send_file         files_sent
        start_file_reproxy      files_reproxied
        start_web_request       web_requests
    );

    # create hooks for %simple things
    while (my ($hook, $stat) = each %simple) {
        eval "\$svc->register_hook('Stats', '$hook', sub { \$sobj->{'$stat'}++; return 0; });";
        return undef if $@;
    }

    # more complicated statistics
    $svc->register_hook('Stats', 'backend_client_assigned', sub {
        my Perlbal::BackendHTTP $be = shift;
        my Perlbal::ClientProxy $cp = $be->{client};
        $sobj->{pending}->{"$cp"} = [ gettimeofday() ];
        ($cp->{high_priority} ? $sobj->{proxy_requests_highpri} : $sobj->{proxy_requests})++;
        return 0;
    });
    $svc->register_hook('Stats', 'backend_response_received', sub {
        my Perlbal::BackendHTTP $be = shift;
        my Perlbal::ClientProxy $obj = $be->{client};
        my $ot = delete $sobj->{pending}->{"$obj"};
        return 0 unless defined $ot;

        # now construct data to put in recent
        if (defined $obj->{req_headers}) {
            my $uri = 'http://' . ($obj->{req_headers}->header('Host') || 'unknown') . $obj->{req_headers}->request_uri;
            push @{$sobj->{recent}}, sprintf('%-6.4f %s', tv_interval($ot), $uri);
            shift(@{$sobj->{recent}}) if scalar(@{$sobj->{recent}}) > 100; # if > 100 items, lose one
        }
        return 0;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    # clean up time
    $svc->unregister_hooks('Stats');
    delete $statobjs{$svc->{name}};
    return 1;
}

# called when we are loaded
sub load {
    # setup a management command to dump statistics
    Perlbal::register_global_hook("manage_command.stats", sub {
        my @res;

        # create temporary object for stats storage
        my $gsobj = Perlbal::Plugin::Stats::Storage->new();

        # dump per service
        foreach my $svc (keys %statobjs) {
            my $sobj = $statobjs{$svc}->[1];

            # for now, simply dump the numbers we have
            foreach my $key (sort @statkeys) {
                push @res, sprintf("%-15s %-25s %12d", $svc, $key, $sobj->{$key});
                $gsobj->{$key} += $sobj->{$key};
            }
        }

        # global stats
        foreach my $key (sort @statkeys) {
            push @res, sprintf("%-15s %-25s %12d", 'total', $key, $gsobj->{$key});
        }

        push @res, ".";
        return \@res;
    });

    # recent requests and how long they took
    Perlbal::register_global_hook("manage_command.recent", sub {
        my @res;
        foreach my $svc (keys %statobjs) {
            my $sobj = $statobjs{$svc}->[1];
            push @res, "$svc $_"
                foreach @{$sobj->{recent}};
        }

        push @res, ".";
        return \@res;
    });

    return 1;
}

# called for a global unload
sub unload {
    # unregister our global hooks
    Perlbal::unregister_global_hook('manage_command.stats');
    Perlbal::unregister_global_hook('manage_command.recent');

    # take out all service stuff
    foreach my $statref (values %statobjs) {
        $statref->[0]->unregister_hooks('Stats');
    }
    %statobjs = ();

    return 1;
}

# statistics storage object
package Perlbal::Plugin::Stats::Storage;

use fields (
    'files_sent',         # files sent from disk (includes reproxies and regular web requests)
    'files_reproxied',    # files we've sent via reproxying (told to by backend)
    'web_requests',       # requests we sent ourselves (no reproxy, no backend)
    'proxy_requests',     # regular requests that went to a backend to be served
    'proxy_requests_highpri', # same as above, except high priority

    'pending',            # hashref; { "obj" => time_start }
    'recent',             # arrayref; strings of recent URIs and times
    );

sub new {
    my Perlbal::Plugin::Stats::Storage $self = shift;
    $self = fields::new($self) unless ref $self;

    # 0 initialize everything here
    $self->{$_} = 0 foreach @Perlbal::Plugin::Stats::statkeys;

    # other setup
    $self->{pending} = {};
    $self->{recent} = [];

    return $self;
}

1;
