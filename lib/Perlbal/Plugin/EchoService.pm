###########################################################################
# simple plugin demonstrating how to create an add-on service for Perlbal
# using the plugin infrastructure
###########################################################################

package Perlbal::Plugin::EchoService;

use strict;
use warnings;

# on load we need to define the service and any paramemters we want
sub load {

    # define the echo service, which instantiates this type of object
    Perlbal::Service::add_role(
            echo => \&Perlbal::Plugin::EchoService::Client::new,
        );

    # add up custom configuration options that people are allowed to set on the echo_service
    Perlbal::Service::add_tunable(
            # allow the following:
            #    SET myservice.echo_delay = 5
            # defines how long to wait between getting text and echoing it back
            echo_delay => {
                des => "Time in seconds to pause before sending text back using the echo service.",
                default => 0, # no delay
                check_role => "echo",
                check_type => "int",
            }
        );

    return 1;
}

# remove the various things we've hooked into, this is required as a way of
# being good to the system...
sub unload {
    Perlbal::Service::remove_tunable('echo_delay');
    Perlbal::Service::remove_role('echo');
    return 1;
}


###########################################################################
# this is the implementation of the client that gets instantiated by the
# service.  (which is really all a service does - instantiate the right
# type of client, and store some information)
###########################################################################

package Perlbal::Plugin::EchoService::Client;
use strict;
use warnings;

use base "Perlbal::Socket";
use fields ('service', # the service we're from
            'buf');    # the buffer of what we're reading

# create a new object of this class
sub new {
    my $class = "Perlbal::Plugin::EchoService::Client";
    my ($service, $sock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($sock);
    $self->{service} = $service;
    $self->{buf} = "";   # what we've read so far, not forming a complete line

    $self->watch_read(1);
    return $self;
}

# called when we are readable - i.e. there is data available
sub event_read {
    my Perlbal::Plugin::EchoService::Client $self = shift;

    # try to read in 1k of data, remember to close if you get undef, as that means
    # something went wrong, or the socket was closed
    my $bref = $self->read(1024);
    return $self->close() unless defined $bref;
    $self->{buf} .= $$bref;

    # now, parse out any lines that we have gotten.  this just removes data line by
    # line so we can handle it.
    while ($self->{buf} =~ s/^(.+?)\r?\n//) {
        my $line = $1;

        # package up a sub to do what we want.  this is in a coderef because we either
        # need to call it now or schedule it for later.  saves some duplication.
        my $do_echo = sub { $self->write("$line\r\n"); };

        # if they want a delay, we have to schedule this for later
        if (my $delay = $self->{service}->{extra_config}->{echo_delay}) {
            # schedule
            Danga::Socket->AddTimer($delay, $do_echo);

        } else {
            # immediately, so run it
            $do_echo->();

        }
    }
}

# called when we are writeable - that is, we are allowed to write data now.  try to
# flush any existing data and then if we have nothing in the write buffer left,
# go ahead and stop notifying us about writeability.
sub event_write {
    my Perlbal::Plugin::EchoService::Client $self = shift;
    $self->watch_write(0) if $self->write(undef);
}

# if we run into some socket error, just close
sub event_err {
    my Perlbal::Plugin::EchoService::Client $self = shift;
    $self->close;
}

# same thing if we get a hup
sub event_hup {
    my Perlbal::Plugin::EchoService::Client $self = shift;
    $self->close;
}

1;
