package Perlbal::Plugin::NotModified;

use Perlbal;
use strict;
use warnings;

# Takes settings in perlbal like:
# SET ss.notmodified.host_pattern = ^example\.com
#
# The value is a regular expression to match against the Host: header on the incoming request.

sub load {
    my $class = shift;
    return 1;
}

sub unload {
    my $class = shift;
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    my $host_check_regex = undef;

    my $start_http_request_hook =  sub {
        my Perlbal::ClientHTTPBase $client = shift;
        my Perlbal::HTTPHeaders $hds = $client->{req_headers};
        return 0 unless $hds;

        my $uri = $hds->request_uri;

        return 0 unless $uri;

        my $host = $hds->header("Host");

        return 0 unless $host;
        return 0 unless $host =~ $host_check_regex;

        my $ims = $hds->header("If-Modified-Since");

        return 0 unless $ims;

        $client->send_response(304, "Not Modified");

        return 1;
    };

    # register things to take in configuration regular expressions
    $svc->register_setter('NotModified', 'host_pattern', sub {
        my ($out, $what, $val) = @_;
        return 0 unless $what && $val;

        my $err = sub {
            $out->("ERROR: $_[0]") if $out;
            return 0;
        };

        unless (length $val) {
            $host_check_regex = undef;
            $svc->unregister_hooks('NotModified');
            return 1;
        }

        $host_check_regex = qr/$val/;
        $svc->register_hook('NotModified', 'start_http_request', $start_http_request_hook);

        return 1;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    $svc->unregister_hooks('NotModified');
    $svc->unregister_setters('NotModified');
    return 1;
}

1;
