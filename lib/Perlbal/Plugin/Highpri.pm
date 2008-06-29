###########################################################################
# plugin that makes some requests high priority.  this is very LiveJournal
# specific, as this makes requests to the client protocol be treated as
# high priority requests.
###########################################################################

package Perlbal::Plugin::Highpri;

use strict;
use warnings;

# keep track of services we're loaded for
our %Services;

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    # create a compiled regexp for very frequent use later
    my $uri_check = qr{^(?:/interface/(?:xmlrpc|flat)|/login\.bml)$};
    my $host_check = undef;

    # setup default extra config info
    $svc->{extra_config}->{highpri_uri_check_str} = '^(?:/interface/(?:xmlrpc|flat)|/login\.bml)$';
    $svc->{extra_config}->{highpri_host_check_str} = 'undef';

    # config setter reference
    my $config_set = sub {
        my ($out, $what, $val) = @_;
        return 0 unless $what && $val;

        # setup an error sub
        my $err = sub {
            $out->("ERROR: $_[0]") if $out;
            return 0;
        };

        # if they said undef, that's not a regexp, that means use none
        my $temp;
        unless ($val eq 'undef' || $val eq 'none' || $val eq 'null') {
            # verify this regexp works?  do it in an eval because qr will die
            # if we give it something invalid
            eval {
                $temp = qr{$val};
            };
            return $err->("Invalid regular expression") if $@ || !$temp;
        }

        # see what they want to set and set it
        if ($what =~ /^uri_pattern/i) {
            $uri_check = $temp;
            $svc->{extra_config}->{highpri_uri_check_str} = $val;
        } elsif ($what =~ /^host_pattern/i) {
            $host_check = $temp;
            $svc->{extra_config}->{highpri_host_check_str} = $val;
        } else {
            return $err->("Plugin understands: uri_pattern, host_pattern");
        }

        # 1 for success!
        return 1;
    };

    # register things to take in configuration regular expressions
    $svc->register_setter('Highpri', 'uri_pattern', $config_set);
    $svc->register_setter('Highpri', 'host_pattern', $config_set);

    # more complicated statistics
    $svc->register_hook('Highpri', 'make_high_priority', sub {
        my Perlbal::ClientProxy $cp = shift;

        # check it against our compiled regexp
        return 1 if $uri_check &&
                    $cp->{req_headers}->request_uri =~ /$uri_check/;
        if ($host_check) {
            my $hostname = $cp->{req_headers}->header('Host');
            return 1 if $hostname && $hostname =~ /$host_check/;
        }

        # doesn't fit, so return 0
        return 0;
    });

    # mark this service as being active in this plugin
    $Services{"$svc"} = $svc;

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    # clean up time
    $svc->unregister_hooks('Highpri');
    $svc->unregister_setters('Highpri');
    return 1;
}

# load global commands for querying this plugin on what's up
sub load {
    # setup a command to see what the patterns are
    Perlbal::register_global_hook('manage_command.patterns', sub {
        my @res = ("High priority pattern buffer:");

        foreach my $svc (values %Services) {
            push @res, "SET $svc->{name}.highpri.uri_pattern = $svc->{extra_config}->{highpri_uri_check_str}";
            push @res, "SET $svc->{name}.highpri.host_pattern = $svc->{extra_config}->{highpri_host_check_str}";
        }

        push @res, ".";
        return \@res;
    });

    return 1;
}

# unload our global commands, clear our service object
sub unload {
    Perlbal::unregister_global_hook('manage_command.patterns');
    %Services = ();
    return 1;
}

1;
