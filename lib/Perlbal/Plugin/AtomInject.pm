package Perlbal::Plugin::AtomInject;

use Perlbal;
use strict;
use warnings;

our @subs;  # subscribers

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    $svc->{enable_put} = 1;

    $svc->register_hook('AtomInject', 'handle_put', sub {
        my Perlbal::ClientHTTP $self = shift;
        my Perlbal::HTTPHeaders $hds = $self->{req_headers};
        return 0 unless $hds;

        return $self->send_response(400, "Invalid method")
            unless $hds->request_method eq "PUT";

        my $uri = $hds->request_uri;
        return $self->send_response(400, "Invalid uri") unless $uri =~ /^\//;
        $self->{scratch}{path} = $uri;
        
        # now abort the normal handle_put processing...
        return 1;
    });

    $svc->register_hook('AtomInject', 'put_writeout', sub {
        my Perlbal::ClientHTTP $self = shift;
        return 1 if $self->{content_length_remain};

        my $data  = join("", map { $$_ } @{$self->{read_buf}});

        # reset our input buffer
        $self->{read_buf}   = [];
        $self->{read_ahead} = 0;

        my $rv = eval { Perlbal::Plugin::AtomStream->InjectFeed(\$data, $self->{scratch}{path}); };
        return $self->send_response(200);
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
