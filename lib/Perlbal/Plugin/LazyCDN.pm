package Perlbal::Plugin::LazyCDN;

use IO::Socket::INET;
use Perlbal;
use Perlbal::ClientHTTPBase;
use strict;
use warnings;

sub load {
    # add up custom configuration options that people are allowed to set
    Perlbal::Service::add_tunable(
            # allow the following:
            #    SET myservice.fallback_service = proxy
            fallback_service => {
                des => "Service name to fall back to when a static get or concat get requests something newer than on disk.",
                check_role => "web_server",
            }
        );

    Perlbal::Service::add_tunable(
            # allow the following:
            #    SET myservice.fallback_udp_ping_addr = 5
            fallback_udp_ping_addr => {
                des => "Address and port to send UDP packets containing URL requests .",
                check_role => "web_server",
                check_type => ["regexp", qr/^\d+\.\d+\.\d+\.\d+:\d+$/, "Expecting IP:port of form a.b.c.d:port."],
            }
        );
    return 1;
}

# remove the various things we've hooked into, this is required as a way of
# being good to the system...
sub unload {
    Perlbal::Service::remove_tunable('fallback_service');
    Perlbal::Service::remove_tunable('fallback_udp_ping_addr');
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    my $socket;

    my $hook = sub {
        my Perlbal::ClientHTTPBase $client = shift;
        my $last_modified = shift; # unix timestamp for last modified of the concatenated files

        my $fallback_service_name = $client->{service}->{extra_config}->{fallback_service};
        return unless $fallback_service_name;

        my $fallback_service = Perlbal->service($fallback_service_name);
        return unless $fallback_service;

        my $req_hd = $client->{req_headers};

        my $uri = $req_hd->request_uri;

        my ($v) = $uri =~ m/\bv=(\d+)\b/;

        if (defined $last_modified) {
            return unless $v;
            return 0 unless $v > $last_modified;
        }

        if (my $fallback_ping_addr = $client->{service}->{extra_config}->{fallback_udp_ping_addr}) {
            $socket ||= _ping_socket($fallback_ping_addr);
            $socket->write($uri);
        }

        $fallback_service->adopt_base_client( $client );

        return 1;
    };

    $svc->register_hook('LazyCDN', 'static_get_poststat_pre_send', $hook);
    $svc->register_hook('LazyCDN', 'concat_get_poststat_pre_send', $hook);

    $svc->register_hook('LazyCDN', 'static_get_poststat_file_missing', $hook);
    $svc->register_hook('LazyCDN', 'concat_get_poststat_file_missing', $hook);

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    return 1;
}

sub _ping_socket {
    my $hostspec = shift;
    my $socket = IO::Socket::INET->new(
            PeerAddr  => $hostspec,
            Proto     => 'udp',
            Broadcast => 1,
            ReuseAddr => 1)
        or warn "Can't bind udp ping socket: $!\n";
    return $socket;
}

1;
