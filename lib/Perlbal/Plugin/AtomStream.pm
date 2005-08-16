###########################################################################
# basic Perlbal statistics gatherer
###########################################################################

package Perlbal::Plugin::AtomStream;

use Perlbal;
use strict;
use warnings;

our @subs;  # subscribers

sub InjectFeed {
    my $class = shift;
    my $atomref = shift;

    my $need_clean = 0;
    foreach my $s (@subs) {
        if ($s->{closed}) {
            $need_clean = 1;
            next;
        }
        $s->write($atomref);
    }

    if ($need_clean) {
        @subs = grep { ! $_->{closed} } @subs;
    }
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    Perlbal::Socket::register_callback(1, sub {
        my $now = time();
        foreach my $s (@subs) {
            next if $s->{closed};
            $s->{alive_time} = $now;
            $s->write(\ "<time>$now</time>\n");
        }
        return 1;
    });

    $svc->register_hook('AtomStream', 'start_http_request', sub {
        my Perlbal::ClientProxy $self = shift;
        my Perlbal::HTTPHeaders $hds = $self->{req_headers};
        return 0 unless $hds;
        my $uri = $hds->request_uri;
        return 0 unless $uri =~ m!^/atom-stream\.xml$!;

        my $res = $self->{res_headers} = Perlbal::HTTPHeaders->new_response(200);
        $res->header("Content-Type", "text/xml");
        $res->header('Connection', 'close');

        push @subs, $self;

        $self->write($res->to_string_ref);
        $self->write(\ "<?xml version='1.0' encoding='utf-8' ?>\n<atomStream>\n");
        return 1;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    return 1;
}

# called when we are loaded
sub load {
    return 1;
}

# called for a global unload
sub unload {
    return 1;
}

1;
