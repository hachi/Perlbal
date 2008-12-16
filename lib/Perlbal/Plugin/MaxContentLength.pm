package Perlbal::Plugin::MaxContentLength;

=head1 NAME

Perlbal::Plugin::MaxContentLength - Reject large requests

=head1 SYNOPSIS

    LOAD MaxContentLength
    CREATE SERVICE cgilike
        # define a service...
        SET max_content_length  = 100000
        SET plugins             = MaxContentLength
    ENABLE cgilike

=head1 DESCRIPTION

This module rejects requests that are larger than a configured limit. If a
request bears a Content-Length header whose value exceeds the
max_content_length value, the request will be rejected with a 413 "Request
Entity Too Large" error.

=head1 AUTHOR

Adam Thomason, E<lt>athomason@sixapart.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2008 Six Apart Ltd.

This module is part of the Perlbal distribution, and as such can be distributed
under the same licence terms as the rest of Perlbal.

=cut

use strict;
use warnings;

use Perlbal;

sub load {
    Perlbal::Service::add_tunable(
        max_content_length => {
            check_role => '*',
            check_type => 'int',
            des => "maximum Content-Length allowed, in bytes. 0 for no limit",
            default => 0,
        },
    );
    return 1;
}

use constant HANDLE_REQUEST => 0;
use constant IGNORE_REQUEST => 1;

sub register {
    my ($class, $svc) = @_;

    my $cfg = $svc->{extra_config};
    return unless $cfg;

    $svc->register_hook('MaxContentLength', 'start_http_request' => sub {
        my $client = shift;
        return IGNORE_REQUEST unless $client;

        # allow request if max is disabled
        return HANDLE_REQUEST unless $cfg->{max_content_length};

        my $headers = $client->{req_headers};
        return HANDLE_REQUEST unless $headers;

        # allow requests which don't have a Content-Length header
        my $length = $headers->header('content-length');
        return HANDLE_REQUEST unless $length;

        # allow requests under the cap
        return HANDLE_REQUEST if $length <= $cfg->{max_content_length};

        $client->send_response(413, "Content too long.\n");
        return IGNORE_REQUEST;
    });
}

sub unregister {
    my ($class, $svc) = @_;

    $svc->unregister_hooks('MaxContentLength');
    return 1;
}

1;
