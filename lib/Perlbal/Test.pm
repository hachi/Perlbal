package Perlbal::Test;
use strict;
use Perlbal;
use POSIX qw( :sys_wait_h );

our $i_am_parent = 0;
our $msock;  # management sock of child
our $to_kill = 0;

END {
    if ($i_am_parent) {
        eval {
            Linux::AIO::max_parallel(0)
                if $Perlbal::OPTMOD_LINUX_AIO;
          };
        kill_all_children_of($$);
    }
}

our %children;
sub learn_pid_tree {
    opendir(P, "/proc") or die;
    my @pids = grep { /^\d+$/ } readdir(P);
    closedir(P);
    foreach my $pid (@pids) {
        my $parent = parent_pid_of($pid);
        push @{$children{$parent} ||= []}, $pid;
    }
}

sub kill_all_children_of {
    my $pid = shift;
    learn_pid_tree() unless %children;
    foreach my $ch (@{$children{$pid} || []}) {
        kill_all_children_of($ch);
        kill 9, $ch;
    }
}

sub parent_pid_of {
    my $pid = shift;
    return undef unless $pid =~ /^\d+$/;
    open(L, "/proc/$pid/status") or return undef;
    while (<L>) {
        next unless /PPid:\s+(\d+)/;
        close L;
        return $1;
    }
    close L;
}

sub start_server {
    my $conf = shift;

    my $child = fork;
    if ($child) {
        $i_am_parent = 1;
        $to_kill = $child;
        my $msock = wait_on_child($child);
        my $rv = waitpid($child, WNOHANG);
        if ($rv) {
            die "Child process (webserver) died.\n";
        }
        print $msock "proc\r\n";
        my $spid = 0;
        while (<$msock>) {
            last if m!^\.\r?\n!;
            next unless /^pid:\s+(\d+)/;
            $spid = $1;
        }
        die "Our child was $child, but we connected and it says it's $spid."
            unless $child == $spid;

        return $msock;
    }

    # child process...

    $conf .= qq{
CREATE SERVICE mgmt   # word
SET mgmt.listen = 127.0.0.1:60000
SET mgmt.role = management
ENABLE mgmt
};

    my $out = sub { print STDOUT join("\n", map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_) . "\n"; };
    Perlbal::run_manage_command($_, $out) foreach split(/\n/, $conf);

    unless (Perlbal::Socket->WatchedSockets() > 0) {
        #kill 15, getppid();
        die "Invalid configuration.  (shouldn't happen?)  Stopping (self=$$).\n";
    }

    Perlbal::run();
    exit 0;
}

# get the manager socket
sub msock {
    return $msock;
}

sub wait_on_child {
    my $pid = shift;

    my($port) = @_;
    my $start = time;
    while (1) {
	$msock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:60000");
	return $msock if $msock;
	select undef, undef, undef, 0.25;
        if (waitpid($pid, WNOHANG) > 0) {
            die "Child process (webserver) died.\n";
        }
	die "Timeout waiting for port $port to startup" if time > $start + 5;
    }
}

1;
