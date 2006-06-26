package Perlbal::Plugin::AutoRemoveLeadingDir;

#
# this plugin auto-removes a leading directory path component
# in the URL, if it's the name of the directory the webserver
# is rooted at.
#
# if docroot = /home/lj/htdocs/stc/
#
# and user requests:
#
#   /stc/img/foo.jpg
#
# Then this plugin will treat that as if it's a request for /img/foo.jpg.
#
# This is useful for css/js/etc to have an "absolute" pathname for
# peer resources (think css having url(/stc/foo.jpg)) that can be served
# from either a separate hostname (stat.livejournal.com) and using a CDN,
# or from www. when cross-domain js restrictions require it.

use Perlbal;
use strict;
use warnings;

sub load   { 1 }
sub unload { 1 }

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    $svc->register_hook('AutoRemoveLeadingDir', 'start_serve_request', sub {
        my Perlbal::ClientHTTPBase $client = shift;
        my $uriref = shift;

        my Perlbal::Service $svc = $client->{service};
        my ($tail) = ($svc->{docroot} =~ m!/([\w-]+)/?$!);
        $$uriref =~ s!^/$tail!! if $tail;
        return 0;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    return 1;
}

1;
