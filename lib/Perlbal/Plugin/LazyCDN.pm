package Perlbal::Plugin::LazyCDN;

use Perlbal;
use strict;
use warnings;

sub load   { 1 }
sub unload { 1 }

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    # FIXME make this configurable
    my $proxy = Perlbal->service( 'off_proxy' );

    $svc->register_hook('LazyCDN', 'concat_get_poststat_pre_send', sub {
        my Perlbal::ClientHTTPBase $client = shift;
        my $last_modified = shift; # unix timestamp for last modified of the concatenated files

        my $req_hd = $client->{req_headers};

        my $uri = $req_hd->request_uri;

        my ($v) = $uri =~ m/\bv=(\d+)\b/;

        return unless $v;
        return 0 unless $v > $last_modified;

        my Perlbal::Service $svc = $client->{service};

        $proxy->adopt_base_client( $client );
        return 1;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    return 1;
}

1;
