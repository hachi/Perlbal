#!/usr/bin/perl
#

package Perlbal;

use constant DEBUG => 0;
use constant DEBUG_OBJ => 1;
use constant TRACK_STATES => 0; # if on, track states for "state changes" command

use strict;
use warnings;
use IO::Socket;
use IO::Handle;
use IO::SendFile;
use IO::File;

use Linux::AIO;
use Sys::Syslog;

use Getopt::Long;
use BSD::Resource;
use Carp qw(cluck croak);
use POSIX ();

use Perlbal::HTTPHeaders;
use Perlbal::Service;
use Perlbal::Socket;
use Perlbal::TCPListener;
use Perlbal::StatsListener;
use Perlbal::ClientManage;
use Perlbal::ClientHTTPBase;
use Perlbal::ClientProxy;
use Perlbal::ClientHTTP;
use Perlbal::BackendHTTP;

$SIG{'PIPE'} = "IGNORE";  # handled manually

our(%hooks);     # hookname => subref
our(%service);   # servicename -> Perlbal::Service
our(%plugins);   # plugin => 1 (shows loaded plugins)
our($last_error);
our $foreground = 1; # default to foreground

# setup a USR1 signal handler that tells us to dump some basic statistics
# of how we're doing to the syslog
$SIG{'USR1'} = sub {
    my $dumper = sub { Perlbal::log('info', $_[0]); };
    foreach my $svc (values %service) {
        run_manage_command("show service $svc->{name}", $dumper);
    }
    run_manage_command('states', $dumper);
    run_manage_command('queues', $dumper);
};

sub error {
    $last_error = shift;
    return 0;
}

# Object instance counts, for debugging and leak detection
our(%ObjCount);  # classname -> instances
our(%ObjTotal);  # classname -> instances
sub objctor {
    if (DEBUG_OBJ) {
        my $caller = (caller)[0];
        $caller .= "-$_[0]" if $_[0];
        $ObjCount{$caller}++;
        $ObjTotal{$caller}++;
    }
}
sub objdtor {
    if (DEBUG_OBJ) {
        my $caller = (caller)[0];
        $caller .= "-$_[0]" if $_[0];
        $ObjCount{$caller}--;
    }
}

sub register_global_hook {
    $hooks{$_[0]} = $_[1];
    return 1;
}

sub unregister_global_hook {
    delete $hooks{$_[0]};
    return 1;
}

sub run_global_hook {
    my $ref = $hooks{$_[0]};
    return $ref->(@_) if defined $ref;
    return undef;
}

sub service_names {
    return sort keys %service;
}

sub service {
    my $class = shift;
    return $service{$_[0]};
}

# returns 1 if command succeeded, 0 otherwise
sub run_manage_command {
    my ($cmd, $out) = @_;  # $out is output stream closure
    $cmd =~ s/\#.*//;
    $cmd =~ s/^\s+//;
    $cmd =~ s/\s+$//;
    $cmd =~ s/^([^=]+)/lc $1/e; # lowercase everything up to an =
    $cmd =~ s/\s+/ /g;
    return 1 unless $cmd =~ /\S/;

    $out ||= sub {};

    my $err = sub {
        $out->("ERROR: $_[0]");
        return 0;
    };

    if ($cmd =~ /^obj$/) {
        foreach (sort keys %ObjCount) {
            $out->("$_ = $ObjCount{$_} (tot=$ObjTotal{$_})");
        }
        $out->('.');
        return 1;
    }

    exit(0) if $cmd eq "shutdown";

    if ($cmd eq 'shutdown graceful') {
        # set connect ahead to 0 for all services so they don't spawn extra backends
        foreach my $svc (values %service) {
            $svc->{connect_ahead} = 0;
        }

        # tell all sockets we're doing a graceful stop
        my $sf = Perlbal::Socket->get_sock_ref;
        foreach my $k (keys %$sf) {
            my Perlbal::Socket $v = $sf->{$k};
            $v->die_gracefully();
        }

        # register a post loop callback that will end the event loop when we only have
        # a single socket left, the AIO socket
        Perlbal::Socket->SetPostLoopCallback(sub {
            my ($descmap, $otherfds) = @_;

            # see what we have here; make sure we have no Clients and no unbored Backends
            foreach my $sock (values %$descmap) {
                my $ref = ref $sock;
                return 1 if $ref =~ /^Perlbal::Client/ && $ref ne 'Perlbal::ClientManage';
                return 1 if $sock->isa('Perlbal::BackendHTTP') && $sock->{state} ne 'bored';
            }
            return 0; # end the event loop and thus we exit perlbal
        });

        # so they know something happened
        $out->('.');

        return 1;
    }

    if ($cmd =~ /^socks(?: (\w+))?$/) {
        my $mode = $1 || "all";
        my $sf = Perlbal::Socket->get_sock_ref;

        if ($mode eq "summary") {
            my %count;
            my $write_buf = 0;
            my $open_files = 0;
            while (my $k = each %$sf) {
                my Perlbal::Socket $v = $sf->{$k};
                $count{ref $v}++;
                $write_buf += $v->{write_buf_size};
                if ($v->isa("Perlbal::ClientHTTPBase")) {
                    my Perlbal::ClientHTTPBase $cv = $v;
                    $open_files++ if $cv->{'reproxy_fd'};
                }
            }

            foreach (sort keys %count) {
                $out->(sprintf("%5d $_", $count{$_}));
            }
            $out->();
            $out->(sprintf("Aggregate write buffer: %.1fk", $write_buf / 1024));
            $out->(sprintf("            Open files: %d", $open_files));

        } elsif ($mode eq "all") {

            my $now = time;
            $out->(sprintf("%5s %6s", "fd", "age"));
            foreach (sort { $a <=> $b } keys %$sf) {
                my $sock = $sf->{$_};
                my $age = $now - $sock->{create_time};
                $out->(sprintf("%5d %5ds %s", $_, $age, $sock->as_string));
            }
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^backends$/) {
        my $sf = Perlbal::Socket->get_sock_ref;

        my %nodes; # { "Backend" => int count }
        foreach my $sock (values %$sf) {
            if ($sock->isa("Perlbal::BackendHTTP")) {
                my Perlbal::BackendHTTP $cv = $sock;
                $nodes{"$cv->{ipport}"}++;
            }
        }

        # now print out text
        foreach my $node (sort keys %nodes) {
            $out->("$node " . $nodes{$node});
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^noverify$/) {
        # shows the amount of time left for each node marked as noverify
        my $now = time;
        foreach my $ipport (keys %Perlbal::BackendHTTP::NoVerify) {
            my $until = $Perlbal::BackendHTTP::NoVerify{$ipport} - $now;
            $out->("$ipport $until");
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^pending$/) {
        # shows pending backend connections by service, node, and age
        my %pend; # { "service" => { "ip:port" => age } }
        my $now = time;

        foreach my $svc (values %service) {
            foreach my $ipport (keys %{$svc->{pending_connects}}) {
                my Perlbal::BackendHTTP $be = $svc->{pending_connects}->{$ipport};
                next unless defined $be;
                $pend{$svc->{name}}->{$ipport} = $now - $be->{create_time};
            }
        }

        foreach my $name (sort keys %pend) {
            foreach my $ipport (sort keys %{$pend{$name}}) {
                $out->("$name $ipport $pend{$name}{$ipport}");
            }
        }
        $out->('.');

        return 1;
    }

    if ($cmd =~ /^states(?:\s+(.+))?$/) {
        my $sf = Perlbal::Socket->get_sock_ref;

        my $svc;
        if (defined $1) {
            $svc = $service{$1};
            return $err->("Service not found.")
                unless defined $svc;
        }

        my %states; # { "Class" => { "State" => int count; } }
        foreach my $sock (values %$sf) {
            my $state = $sock->state;
            next unless defined $state;
            if (defined $svc) {
                next unless $sock->isa('Perlbal::ClientProxy') ||
                            $sock->isa('Perlbal::BackendHTTP') ||
                            $sock->isa('Perlbal::ClientHTTP');
                next unless $sock->{service} == $svc;
            }
            $states{ref $sock}->{$state}++;
        }

        # now print out text
        foreach my $class (sort keys %states) {
            foreach my $state (sort keys %{$states{$class}}) {
                $out->("$class $state " . $states{$class}->{$state});
            }
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^queues$/) {
        my $now = time;

        foreach my $svc (values %service) {
            next unless $svc->{role} eq 'reverse_proxy';

            my ($age, $count) = (0, scalar(@{$svc->{waiting_clients}}));
            my Perlbal::ClientProxy $oldest = $svc->{waiting_clients}->[0];
            $age = $now - $oldest->{create_time} if defined $oldest;
            $out->("$svc->{name}-normal.age $age");
            $out->("$svc->{name}-normal.count $count");

            ($age, $count) = (0, scalar(@{$svc->{waiting_clients_highpri}}));
            $oldest = $svc->{waiting_clients_highpri}->[0];
            $age = $now - $oldest->{create_time} if defined $oldest;
            $out->("$svc->{name}-highpri.age $age");
            $out->("$svc->{name}-highpri.count $count");
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^state changes$/) {
        my $hr = Perlbal::Socket->get_statechange_ref;
        my %final; # { "state" => count }
        while (my ($obj, $arref) = each %$hr) {
            $out->("$obj: " . join(', ', @$arref));
            $final{$arref->[-1]}++;
        }
        foreach my $k (sort keys %final) {
            $out->("$k $final{$k}");
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^show service (\w+)$/) {
        my $sname = $1;
        my Perlbal::Service $svc = $service{$sname};
        return $err->("Unknown service") unless $svc;
        $svc->stats_info($out);
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^server (\w+) ?= ?(.+)$/) {
        my ($key, $val) = ($1, $2);
        return $err->("Expected numeric parameter") unless $val =~ /^-?\d+$/;

        if ($key eq "max_connections") {
            my $rv = setrlimit(RLIMIT_NOFILE, $val, $val);
            unless (defined $rv && $rv) {
                if ($> == 0) {
                    $err->("Unable to set limit.");
                } else {
                    $err->("Need to be root to increase max connections.");
                }
            }
        } elsif ($key eq "nice_level") {
            my $rv = POSIX::nice($val);
            $err->("Unable to renice: $!")
                unless defined $rv;
                    
        } elsif ($key eq "aio_threads") {

        }

        return 1;
    }

    if ($cmd =~ /^create service (\w+)$/) {
        my $name = $1;
        return $err->("service '$name' already exists") if $service{$name};
        $service{$name} = Perlbal::Service->new($name);
        return 1;
    }

    if ($cmd =~ /^show service$/) {
        foreach my $name (sort keys %service) {
            my $svc = $service{$name};
            $out->("$name $svc->{listen} " . ($svc->{enabled} ? "ENABLED" : "DISABLED"));
        }
        $out->('.');
        return 1;
    }

    if ($cmd =~ /^set (\w+)\.([\w\.]+) ?= ?(.+)$/) {
        my ($name, $key, $val) = ($1, $2, $3);
        my $svc = $service{$name};
        return $err->("service '$name' does not exist") unless $svc;
        return $svc->set($key, $val, $out);
    }

    if ($cmd =~ /^(disable|enable) (\w+)$/) {
        my ($verb, $name) = ($1, $2);
        my $svc = $service{$name};
        return $err->("service '$name' does not exist") unless $svc;
        return $svc->$verb($out);
    }

    if ($cmd =~ /^(un)?load (\w+)$/) {
        my $un = $1 ? $1 : '';
        my $fn = $2;
        if (length $fn) {
            # since we lowercase our input, uppercase the first character here
            $fn = uc($1) . lc($2) if $fn =~ /^(.)(.*)$/;
            eval "use Perlbal::Plugin::$fn; Perlbal::Plugin::$fn->${un}load;";
            return $err->($@) if $@;
            $plugins{$fn} = $un ? 0 : 1;
        }
        return 1;
    }

    if ($cmd =~ /^plugins$/) {
        foreach my $svc (values %service) {
            next unless @{$svc->{plugin_order}};
            $out->(join(' ', $svc->{name}, @{$svc->{plugin_order}}));
        }
        $out->('.');
        return 1;
    }

    # call any hooks if they've been defined
    my $lcmd = $cmd =~ /^(.+?)\s+/ ? $1 : $cmd;
    my $rval = run_global_hook("manage_command.$lcmd", $cmd);
    return $out->($rval, '.') if defined $rval;

    return $err->("unknown command: $cmd");
}

sub load_config {
    my ($file, $writer) = @_;
    open (F, $file) or die "Error opening config file ($file): $!\n";
    while (<F>) {
        return 0 unless run_manage_command($_, $writer);
    }
    close(F);
    return 1;
}

sub daemonize {
    my($pid, $sess_id, $i);

    # note that we're not in the foreground (for logging purposes)
    $foreground = 0;

    # required before fork: (as of Linux::AIO 1.1, but may change)
    Linux::AIO::max_parallel(0);

    ## Fork and exit parent
    if ($pid = fork) { exit 0; }

    ## Detach ourselves from the terminal
    croak "Cannot detach from controlling terminal"
        unless $sess_id = POSIX::setsid();

    ## Prevent possibility of acquiring a controling terminal
    $SIG{'HUP'} = 'IGNORE';
    if ($pid = fork) { exit 0; }

    ## Change working directory
    chdir "/";

    ## Clear file creation mask
    umask 0;

    ## Close open file descriptors
    close(STDIN);
    close(STDOUT);
    close(STDERR);

    ## Reopen stderr, stdout, stdin to /dev/null
    open(STDIN,  "+>/dev/null");
    open(STDOUT, "+>&STDIN");
    open(STDERR, "+>&STDIN");
}

sub run {
    # setup for logging
    openlog('perlbal', 'pid', 'daemon');
    Perlbal::log('info', 'beginning run');
    
    # number of AIO threads.  the number of outstanding requests isn't
    # affected by this
    Linux::AIO::min_parallel(3);

    # register Linux::AIO's pipe which gets written to from threads
    # doing blocking IO
    my $aio_fd = Linux::AIO::poll_fileno;

    Perlbal::Socket->OtherFds(
        $aio_fd => sub {
            # run any callbacks on async file IO operations
            Linux::AIO::poll_cb();
          },
    );

    # begin the overall loop to try to capture if Perlbal dies at some point
    # so we can have a log of it
    eval {
        # wait for activity
        Perlbal::Socket->EventLoop();
    };

    # closing messages
    if ($@) {
        Perlbal::log('critical', "crash log: $_") foreach split(/\r?\n/, $@);
    }
    Perlbal::log('info', 'ending run');
    closelog();
}

sub log {
    # simple logging functionality
    if ($foreground) {
        # syslog acts like printf so we have to use printf and append a \n
        shift; # ignore the first parameter (info, warn, critical, etc)
        printf(shift(@_) . "\n", @_);
    } else {
        # just pass the parameters to syslog
        syslog(@_);
    }
}

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

1;
